// MARK: - UserData

/// UserData represents the user data associated with an Epoll or Kqueue event.
public enum UserData {
  /// A file descriptor.
  case fd(Int32)
  /// An UInt32.
  case u32(UInt32)
  /// An UInt64.
  case u64(UInt64)
  /// A raw pointer.
  case ptr(UnsafeMutableRawPointer)

  /// Creates a UserData enum by converting the provided data value
  /// from UInt64 to UInt32. The provided UserData must be a .u64.
  public init?(asU32 d: UserData) {
    guard case let .u64(u) = d, let u32 = UInt32(exactly: u) else {
      return nil
    }
    self = .u32(u32)
  }

  /// Creates a UserData enum by converting the provided data value
  /// from UInt64 to an In32. The provided UserData must be a .u64.
  public init?(asFD d: UserData) {
    guard case let .u64(u) = d, let i32 = Int32(exactly: u) else {
      return nil
    }
    self = .fd(i32)
  }

  /// Creates a UserData enum by casting the provided data value
  /// from UInt64 to a raw pointer. The provided UserData must be a .u64.
  public init?(asPtr d: UserData) {
    guard case let .u64(u64) = d, let u = UInt(exactly: u64) else {
      return nil
    }
    guard let p = UnsafeMutableRawPointer(bitPattern: u) else {
      return nil
    }
    self = .ptr(p)
  }
}

// MARK: - UserData+Equatable

extension UserData: Equatable {
  /// Equatable implementation for UserData.
  public static func ==(lhs: UserData, rhs: UserData) -> Bool {
    switch (lhs, rhs) {
    case let (.fd(l), .fd(r)):
      return l == r
    case let (.u32(l), .u32(r)):
      return l == r
    case let (.u64(l), .u64(r)):
      return l == r
    case let (.ptr(l), .ptr(r)):
      return l == r
    default:
      return false
    }
  }
}
