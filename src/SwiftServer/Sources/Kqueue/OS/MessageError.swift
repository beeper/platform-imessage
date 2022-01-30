// MARK: - MessageError

/// MessageError is a String-based error that can be created with additional
/// contextual key-value pairs.
public struct MessageError: Swift.Error {
  /// The error message.
  public let message: String

  /// Creates a MessageError with the provided message and optional additional
  /// context information.
  public init(_ message: String, context: [String: String] = [:]) {
    if context.isEmpty {
      self.message = message
    } else {
      let prefix = context.map({ "\($0.key): \($0.value)" }).joined(separator: ", ")
      self.message = "\(prefix): \(message)"
    }
  }
}

// MARK: - MessageError+CustomStringConvertible

extension MessageError: CustomStringConvertible {
  /// The string representation of the error.
  public var description: String {
    return message
  }
}
