// MARK: - SignalSet

/// SignalSet is a set of signals.
public struct SignalSet {

  // MARK: - Properties

  private var sigset = sigset_t()

  // MARK: - Constructors

  private init(mask sigset: sigset_t) {
    self.sigset = sigset
  }

  /// Creates a SignalSet filled with all signals if fill is true,
  /// or empty if false.
  public init(fill: Bool) throws {
    let ret: Int32
    if fill {
      ret = sigfillset(&sigset)
    } else {
      ret = sigemptyset(&sigset)
    }
    try CError.makeAndThrow(fromReturnCode: ret)
  }

  /// Creates a SignalSet with just the specified signals inserted.
  public init(insert signals: [Signal]) throws {
    try self.init(fill: false)
    for sig in signals {
      let ret = sigaddset(&sigset, sig.value)
      try CError.makeAndThrow(fromReturnCode: ret)
    }
  }

  // MARK: - Methods

  /// Inserts `signal` into the SignalSet.
  public mutating func insert(signal: Signal) throws {
    let ret = sigaddset(&sigset, signal.value)
    try CError.makeAndThrow(fromReturnCode: ret)
  }

  /// Removes `signal` from the SignalSet.
  public mutating func remove(signal: Signal) throws {
    let ret = sigdelset(&sigset, signal.value)
    try CError.makeAndThrow(fromReturnCode: ret)
  }

  /// Returns true if the SignalSet contains `signal`.
  public func contains(signal: Signal) throws -> Bool {
    var mask = sigset // copy so "mutating" is not required
    let ret = sigismember(&mask, signal.value)
    try CError.makeAndThrow(fromReturnCode: ret)
    return ret == 1
  }

  /// Blocks (or unblocks) the signals from this SignalSet,
  /// depending the specified `mode`. See sigprocmask(2) for
  /// details.
  @discardableResult
  public func block(mode: BlockMode = .setMask) throws -> SignalSet {
    var mask = sigset // copy so "mutating" is not required
    var old = sigset_t()
    let ret = pthread_sigmask(mode.value, &mask, &old)
    try CError.makeAndThrow(fromErrNo: ret)

    return SignalSet(mask: old)
  }

  /// Returns the C sigset_t struct for this SignalSet.
  public func toCStruct() -> sigset_t {
    return sigset
  }

  #if os(Linux)

  /// Linux only. Creates a SignalFileDescriptor for this SignalSet.
  /// See signalfd(2) for details.
  public mutating func fileDescriptor(replacing fd: FileDescriptor? = nil, flags: Flags = []) throws -> SignalFileDescriptor {
    let val = fd?.fileDescriptor ?? -1
    let ret = signalfd(val, &sigset, flags.rawValue)
    try CError.makeAndThrow(fromReturnCode: ret)

    if let fd = fd, let sfd = fd as? SignalFileDescriptor {
      return sfd
    }
    return SignalFileDescriptor(ret)
  }

  #endif
}

// MARK: - SignalSet+BlockMode

extension SignalSet {
  /// BlockMode indicates the block mode for a SignalSet. See
  /// sigprocmask(2) for details.
  public enum BlockMode {
    case block
    case unblock
    case setMask

    var value: Int32 {
      guard let v = BlockMode.toValues[self] else {
        fatalError("unknown BlockMode enum: \(self)")
      }
      return v
    }

    static func make(_ value: Int32) -> BlockMode? {
      return fromValues[value]
    }

    private static let toValues: [BlockMode: Int32] = [
      .block: SIG_BLOCK,
      .unblock: SIG_UNBLOCK,
      .setMask: SIG_SETMASK,
    ]

    private static let fromValues: [Int32: BlockMode] = [
      SIG_BLOCK: .block,
      SIG_UNBLOCK: .unblock,
      SIG_SETMASK: .setMask,
    ]
  }
}

#if os(Linux)

// MARK: - SignalSet+Flags

extension SignalSet {
  /// Linux only. Configure the file descriptor for a SignalSet.
  public struct Flags: OptionSet {
    public let rawValue: Int32

    public init(rawValue: Int32) {
      self.rawValue = rawValue
    }

    public static let nonBlock = Flags(rawValue: Int32(SFD_NONBLOCK))
    public static let cloExec = Flags(rawValue: Int32(SFD_CLOEXEC))
  }
}

#endif
