import Foundation

// forked from https://rderik.com/blog/using-kernel-queues-kqueue-notifications-in-swift/

public class Kqueue {
    public static func observeProcessExit(pid: UInt, _ completion: @escaping () -> Void) throws {
        let kq = kqueue()
        if kq == -1 {
            throw ErrorMessage("Error creating kqueue")
            // exit(EXIT_FAILURE)
        }

        var sockKevent = kevent(
            ident: pid,
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_RECEIPT),
            fflags: NOTE_EXIT,
            data: 0,
            udata: nil
        )
        kevent(kq, &sockKevent, 1, nil, 0, nil)

        DispatchQueue.global(qos: .utility).async {
            var event = kevent()
            while true {
                let status = kevent(kq, nil, 0, &event, 1, nil)
                if status == 0 {
                    debugLog("observeProcessExit: timeout")
                } else if status > 0 {
                    completion()
                    break
                } else {
                    debugLog("observeProcessExit: error reading kevent")
                    close(kq)
                    // exit(EXIT_FAILURE)
                }
            }
            debugLog("observeProcessExit: kevent loop ended")
            close(kq)
        }
    }
}
