import NodeAPI
import IMessage

enum PlatformAPINodeRuntime {
    @NodeActor
    static func makeRuntime() -> PlatformAPI.Runtime {
        let sentryQueue = try? NodeAsyncQueue(label: "platform-api-sentry")
        return PlatformAPI.Runtime(
            reportMessageToSentry: { message in
                try sentryQueue?.run {
                    try Node.texts.Sentry.captureMessage(message)
                }
            }
        )
    }
}
