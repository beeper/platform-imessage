import Foundation
import CWindowControl

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

    public static func isUnresponsive(_ pid: pid_t) throws -> Bool {
        var psn = ProcessSerialNumber()
        let err = TXTGetProcessForPID(pid, &psn)
        if err != kOSReturnSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err))
        }

        let cid = CGSDefaultConnectionForThread()
        return CGSEventIsAppUnresponsive(cid, &psn)
    }
}
