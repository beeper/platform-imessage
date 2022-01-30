import Foundation

// MARK: - Kqueue

/// Darwin only. Kqueue implements the Darwin kqueue mechanism. See kqueue(2).
public struct Kqueue: FileDescriptor {

  // MARK: - Properties

  /// The file descriptor of this kqueue instance.
  public let fileDescriptor: Int32

  // MARK: - Constructors

  /// Creates a kqueue instance.
  public init() throws {
    let ret = kqueue()
    try CError.makeAndThrow(fromReturnCode: ret)
    self.fileDescriptor = ret
  }

  // MARK: - Methods

  /// Polls for and returns available events in `events`. Events in `changes` are first added,
  /// updated or removed as requested by the event's flags. The call blocks if no events
  /// are immediately available. If timeout is set, unblocks after this delay if no events are
  /// available. Returns the number of events available. No more than `events.count` events
  /// will be returned.
  public func poll(with changes: [Kevent], into events: inout [Kevent], timeout: TimeInterval? = nil) throws -> Int {
    let inKevs = changes.map({ $0.toCStruct() })
    var outKevs = Array<kevent>(repeating: kevent(), count: events.count)

    let ret: Int32
    if let timeout = timeout {
      var ts = timeout.toTimeSpec()
      ret = kevent(fileDescriptor, inKevs, Int32(inKevs.count), &outKevs, Int32(outKevs.count), &ts)
    } else {
      ret = kevent(fileDescriptor, inKevs, Int32(inKevs.count), &outKevs, Int32(outKevs.count), nil)
    }
    try CError.makeAndThrow(fromReturnCode: ret)

    // fill events list with results
    for i in 0..<Int(ret) {
      if let ev = Kevent(outKevs[i]) {
        events[i] = ev
      }
    }
    return Int(ret)
  }

  /// Releases the resources for this file descriptor.
  public func close() throws {
    let ret = Darwin.close(fileDescriptor)
    try CError.makeAndThrow(fromReturnCode: ret)
  }
}
