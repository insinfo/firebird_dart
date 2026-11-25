import 'dart:collection';

import 'types.dart';

/// Column layout shared by all rows of a result.
class FbResultSchema {
  final List<FbColumn> columns;
  late final List<String> names = [for (final c in columns) c.name];
  late final Map<String, int> _index = () {
    final m = <String, int>{};
    for (var i = 0; i < columns.length; i++) {
      m.putIfAbsent(columns[i].name, () => i);
    }
    return m;
  }();
  late final Map<String, int> _lowerIndex = {
    for (final e in _index.entries) e.key.toLowerCase(): e.value,
  };

  FbResultSchema(this.columns);

  /// Position of column [name] (exact match first, then case-insensitive),
  /// or -1.
  int indexOf(String name) =>
      _index[name] ?? _lowerIndex[name.toLowerCase()] ?? -1;
}

/// One result row. Values can be read by position or by column name.
class FbRow {
  final List<Object?> values;
  final FbResultSchema schema;

  FbRow(this.values, this.schema);

  int get length => values.length;

  /// Value by position (`int`) or by column name (`String`, case-insensitive
  /// fallback).
  Object? operator [](Object key) {
    if (key is int) return values[key];
    if (key is String) {
      final i = schema.indexOf(key);
      if (i < 0) throw ArgumentError.value(key, 'key', 'unknown column');
      return values[i];
    }
    throw ArgumentError.value(key, 'key', 'must be int or String');
  }

  T get<T>(Object key) => this[key] as T;

  Map<String, Object?> toMap() {
    final names = schema.names;
    return {for (var i = 0; i < values.length; i++) names[i]: values[i]};
  }

  @override
  String toString() => toMap().toString();
}

/// Materialized result of a statement.
class FbResult extends ListBase<FbRow> {
  final FbResultSchema schema;
  final List<FbRow> _rows;

  /// Rows inserted, updated or deleted by a DML statement.
  final int affectedRows;

  FbResult(this.schema, this._rows, {this.affectedRows = 0});

  List<FbColumn> get columns => schema.columns;

  @override
  int get length => _rows.length;

  @override
  set length(int value) => throw UnsupportedError('FbResult is read-only');

  @override
  FbRow operator [](int index) => _rows[index];

  @override
  void operator []=(int index, FbRow value) =>
      throw UnsupportedError('FbResult is read-only');

  List<Map<String, Object?>> toMaps() => [for (final r in _rows) r.toMap()];

  /// Rows as `{table: {column: value}}`, using each column's source table
  /// (expressions go under `''`).
  List<Map<String, Map<String, Object?>>> toTableMaps() {
    final cols = schema.columns;
    return [
      for (final r in _rows)
        () {
          final m = <String, Map<String, Object?>>{};
          for (var i = 0; i < cols.length; i++) {
            final table = cols[i].relationName;
            (m[table] ??= <String, Object?>{})[cols[i].name] = r.values[i];
          }
          return m;
        }(),
    ];
  }
}
