import Dispatch
import Foundation
import IMessageCore

func runOnMainThread<T>(fn: () throws -> T) rethrows -> T {
    Log.default.debug("runOnMainThread: Thread.isMainThread=\(Thread.isMainThread) queueName=\(__dispatch_queue_get_label(nil))")
    if Thread.isMainThread {
        return try fn()
    }
    return try DispatchQueue.main.sync {
        try fn()
    }
}
