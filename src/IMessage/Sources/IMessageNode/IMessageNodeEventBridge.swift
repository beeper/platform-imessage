import NodeAPI
import IMessage

enum IMessageNodeEventBridge {
    @NodeActor
    static func setEventCallback(_ onEvent: NodeFunction) throws {
        let eventQueue = try NodeAsyncQueue(label: "polling-lifecycle-events")
        let sentryQueue = try? NodeAsyncQueue(label: "polling-lifecycle-sentry")
        let onEvent = SendableBox(onEvent)
        IMessageHost.setEventCallback { events in
            try eventQueue.run {
                let nodeEvents = try NodeBridgeUtilities.nodeArray(from: events.map { $0.jsonObject() })
                try onEvent.value.call([nodeEvents])
            }
        } reportToSentry: { message in
            try? sentryQueue?.run {
                try Node.texts.Sentry.captureMessage(message)
            }
        }
    }
}
