import Foundation

// MARK: TimeInterval extensions

extension TimeInterval {
  /// Creates a TimeInterval from a timespec C struct.
  public init(from spec: timespec) {
    let secs = Int(spec.tv_sec)
    let ns = Int(spec.tv_nsec)
    let t = TimeInterval(Double(secs) + (Double(ns) / 1_000_000_000))
    self = t
  }

  /// Creates a TimeInterval from a timeval C struct.
  public init(from val: timeval) {
    let secs = Int(val.tv_sec)
    let us = Int(val.tv_usec)
    let t = TimeInterval(Double(secs) + (Double(us) / 1_000_000))
    self = t
  }

  /// Returns a C timespec struct corresponding to this TimeInterval.
  public func toTimeSpec() -> timespec {
    var ts = timespec()

    ts.tv_sec = Int(self)
    ts.tv_nsec = Int(self.truncatingRemainder(dividingBy: 1) * 1_000_000_000)

    return ts
  }

  /// Returns a C timeval struct corresponding to this TimeInterval.
  public func toTimeVal() -> timeval {
    var val = timeval()

    val.tv_sec = Int(self)
    let us = Int(self.truncatingRemainder(dividingBy: 1) * 1_000_000)
    #if os(Linux)
      val.tv_usec = Int(us)
    #else
      val.tv_usec = Int32(us)
    #endif

    return val
  }
}
