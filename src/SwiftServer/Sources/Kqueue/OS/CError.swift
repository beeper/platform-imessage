// MARK: - CError

/// CError is an error thrown by a C system call. It may be from
/// a typical -1 return code that sets `errno`, from a `getaddrinfo` call
/// or directly from an `errno`.
public struct CError: Swift.Error {
  /// The error code.
  public let code: Int32
  /// The error message as returned by `strerror` or `gai_strerror`.
  public let message: String

  private init?(fromReturnCode code: Int32, errorValue: Int32 = -1) {
    guard code == errorValue else {
      return nil
    }

    self.code = errno
    self.message = String(validatingUTF8: strerror(errno)) ?? ""
  }

  private init?(fromGAICode code: Int32) {
    // getaddrinfo is an error if != 0
    guard code != 0 else {
      return nil
    }

    self.code = code
    self.message = String(validatingUTF8: gai_strerror(code)) ?? ""
  }

  private init?(fromErrNo errno: Int32) {
    // errno == 0 means no error
    guard errno != 0 else {
      return nil
    }

    self.code = errno
    self.message = String(validatingUTF8: strerror(errno)) ?? ""
  }

  /// Creates and throws the corresponding CError if the `code` is equal
  /// to `errorValue`, otherwise is a no-op.
  public static func makeAndThrow(fromReturnCode code: Int32, errorValue: Int32 = -1) throws {
    if let err = CError(fromReturnCode: code, errorValue: errorValue) {
      throw err
    }
  }

  /// Creates and throws the corresponding CError if `errno` is not equal
  /// to 0, otherwise is a no-op.
  public static func makeAndThrow(fromErrNo errno: Int32) throws {
    if let err = CError(fromErrNo: errno) {
      throw err
    }
  }

  /// Creates and throws the corresponding CError if `code` is not equal
  /// to 0, otherwise is a no-op.
  public static func makeAndThrow(fromGAICode code: Int32) throws {
    if let err = CError(fromGAICode: code) {
      throw err
    }
  }
}

// MARK: - CError+CustomStringConvertible

extension CError: CustomStringConvertible {
  /// The string description of the error.
  public var description: String {
    return "error \(code): \(message)"
  }
}
