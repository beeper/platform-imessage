// MARK: - Closable

/// Any type that can (and typically must) be closed.
public protocol Closable {
  func close() throws
}

// MARK: - FileDescriptor

/// Any resource that can be represented with a file descriptor. A file
/// descriptor is also Closable.
public protocol FileDescriptor: Closable {
  var fileDescriptor: Int32 { get }
}

// MARK: - Int32+FileDescriptor

extension Int32: FileDescriptor {
  /// The file descriptor for an Int32 is the value of the Int32 itself.
  public var fileDescriptor: Int32 {
    return self
  }

  /// Releases the resource associated with this file descriptor.
  public func close() throws {
    let ret = Darwin.close(fileDescriptor)
    try CError.makeAndThrow(fromReturnCode: ret)
  }
}
