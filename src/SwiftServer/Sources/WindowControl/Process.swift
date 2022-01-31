import Foundation

public enum Process {
    public static func monitorExit(pid: pid_t, _ completion: @escaping () -> Void) throws {
        // NOTE(kb): works without queue too but better to assign lower priority
        let dsp = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: DispatchQueue.global(qos: .utility))
        dsp.setEventHandler {
            completion()
            dsp.cancel()
        }
        dsp.resume()
    }
}
