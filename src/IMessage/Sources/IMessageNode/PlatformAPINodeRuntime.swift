import NodeAPI
import IMessage
import IMessageCore

enum PlatformAPINodeRuntime {
    @NodeActor
    static func makeRuntime() -> PlatformAPI.Runtime {
        let runtimeQueue = try? NodeAsyncQueue(label: "platform-api-runtime")
        let sentryQueue = try? NodeAsyncQueue(label: "platform-api-sentry")
        return PlatformAPI.Runtime(
            makeCallbackQueue: { label in
                guard let runtimeQueue else {
                    throw ErrorMessage("PlatformAPI Node runtime queue is unavailable")
                }
                return try await runtimeQueue.run {
                    let queue = try NodeAsyncQueue(label: label)
                    return PlatformAPI.CallbackQueue { action in
                        try queue.run(action)
                    }
                }
            },
            reportMessageToSentry: { message in
                try sentryQueue?.run {
                    try Node.texts.Sentry.captureMessage(message)
                }
            },
            addCleanupHook: { action in
                guard let runtimeQueue else {
                    return PlatformAPI.CleanupHook(remove: {})
                }
                return try await runtimeQueue.run {
                    let cleanupHook = try NodeEnvironment.current.addCleanupHook { completion in
                        action {
                            completion()
                        }
                    }
                    let hook = SendableBox(cleanupHook)
                    return PlatformAPI.CleanupHook {
                        try runtimeQueue.run {
                            try NodeEnvironment.current.removeCleanupHook(hook.value)
                        }
                    }
                }
            }
        )
    }
}
