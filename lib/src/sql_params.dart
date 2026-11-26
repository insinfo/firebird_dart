import 'dart:collection';

import 'exceptions.dart';

/// SQL with `@name` placeholders rewritten to positional `?`.
class NamedSql {
  final String sql;
  final List<String> names;
  NamedSql(this.sql, this.names);

  List<Object?> bind(Map<String, Object?> params) => [
        for (final n in names)
          if (params.containsKey(n))
            params[n]
          else
            throw FbUsageException('Missing value for parameter @$n'),
      ];
}

final LinkedHashMap<String, NamedSql> _cache = LinkedHashMap();
const int _cacheSize = 256;

/// Rewrites `@name` placeholders to `?`, ignoring string literals, quoted
/// identifiers and comments. `@` is not used by Firebird SQL, so PSQL
/// `:variables` inside EXECUTE BLOCK are left alone.
NamedSql parseNamedSql(String sql) {
  final hit = _cache.remove(sql);
  if (hit != null) {
    _cache[sql] = hit;
    return hit;
  }
  final out = StringBuffer();
  final names = <String>[];
  var i = 0;
  final n = sql.length;
  while (i < n) {
    final c = sql.codeUnitAt(i);
    if (c == 0x27 || c == 0x22) {
      // '...' literal or "..." identifier; doubled quote escapes.
      final start = i++;
      while (i < n) {
        if (sql.codeUnitAt(i) == c) {
          if (i + 1 < n && sql.codeUnitAt(i + 1) == c) {
            i += 2;
            continue;
          }
          i++;
          break;
        }
        i++;
      }
      out.write(sql.substring(start, i));
    } else if (c == 0x2D && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2D) {
      final end = sql.indexOf('\n', i);
      final stop = end < 0 ? n : end;
      out.write(sql.substring(i, stop));
      i = stop;
    } else if (c == 0x2F && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2A) {
      final end = sql.indexOf('*/', i + 2);
      final stop = end < 0 ? n : end + 2;
      out.write(sql.substring(i, stop));
      i = stop;
    } else if (c == 0x40 && i + 1 < n && _isIdentStart(sql.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < n && _isIdentPart(sql.codeUnitAt(j))) {
        j++;
      }
      names.add(sql.substring(i + 1, j));
      out.write('?');
      // postgres_fork style type hint (`@id:int4`): accepted and ignored.
      if (j + 1 < n &&
          sql.codeUnitAt(j) == 0x3A &&
          _isIdentStart(sql.codeUnitAt(j + 1))) {
        j += 2;
        while (j < n && _isIdentPart(sql.codeUnitAt(j))) {
          j++;
        }
      }
      i = j;
    } else {
      out.writeCharCode(c);
      i++;
    }
  }
  final parsed = NamedSql(out.toString(), names);
  _cache[sql] = parsed;
  if (_cache.length > _cacheSize) _cache.remove(_cache.keys.first);
  return parsed;
}

bool _isIdentStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isIdentPart(int c) =>
    _isIdentStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x24;

/// Normalises the `params` argument of the query methods into the SQL to
/// prepare and the positional values.
(String, List<Object?>) resolveParams(String sql, Object? params) {
  if (params == null) return (sql, const []);
  if (params is List) return (sql, params.cast<Object?>());
  if (params is Map<String, Object?>) {
    final named = parseNamedSql(sql);
    return (named.sql, named.bind(params));
  }
  throw FbUsageException(
      'params must be a List (for ?) or a Map<String, Object?> (for @name)');
}

/// Whether [sql] starts (after blanks and comments) with SELECT or WITH.
/// Only such statements run in the read-only auto-commit transaction:
/// Firebird 5 also reports DML with RETURNING as a cursor.
bool isSelectSql(String sql) {
  var i = 0;
  final n = sql.length;
  while (i < n) {
    final c = sql.codeUnitAt(i);
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x28) {
      i++; // blanks and opening parentheses
    } else if (c == 0x2D && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2D) {
      final end = sql.indexOf('\n', i);
      if (end < 0) return false;
      i = end + 1;
    } else if (c == 0x2F && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2A) {
      final end = sql.indexOf('*/', i + 2);
      if (end < 0) return false;
      i = end + 2;
    } else {
      break;
    }
  }
  bool word(String w) {
    if (i + w.length > n) return false;
    if (sql.substring(i, i + w.length).toUpperCase() != w) return false;
    return i + w.length == n || !_isIdentPart(sql.codeUnitAt(i + w.length));
  }

  return word('SELECT') || word('WITH');
}
