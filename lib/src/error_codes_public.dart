/// Firebird status codes applications commonly test, for use with
/// `FbException.hasCode` / `FbException.errorCode`.
abstract final class FbErrorCode {
  static const int arithmeticException = 335544321;
  static const int conversionError = 335544334;
  static const int deadlock = 335544336;
  static const int integrityFail = 335544342;
  static const int lockConflict = 335544345;
  static const int notValid = 335544347;
  static const int noDuplicates = 335544349;
  static const int noPermission = 335544352;
  static const int readOnlyTransaction = 335544361;
  static const int updateConflict = 335544451;
  static const int foreignKey = 335544466;
  static const int login = 335544472;
  static const int lockTimeout = 335544510;
  static const int userException = 335544517;
  static const int checkConstraint = 335544558;
  static const int dsqlError = 335544569;
  static const int columnUnknown = 335544578;
  static const int tableUnknown = 335544580;
  static const int procedureUnknown = 335544581;
  static const int tokenUnknown = 335544634;
  static const int singletonSelect = 335544652;
  static const int uniqueKeyViolation = 335544665;
  static const int networkError = 335544721;
  static const int connectionLost = 335544741;
  static const int cancelled = 335544794;
  static const int stringTruncation = 335544914;

  /// Codes reporting a PRIMARY KEY / UNIQUE violation.
  static const Set<int> uniqueViolations = {uniqueKeyViolation, noDuplicates};
}
