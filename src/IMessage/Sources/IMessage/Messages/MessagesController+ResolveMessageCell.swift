import Foundation
import IMDatabase
import IMessageCore

enum MessageCellResolution: Equatable {
    case direct(partIndex: Int?)
    case closestSelectable
    case partNotFound
}

// Pure branch selection, split out so it's unit-testable without a live Messages.app.
//   partIndex != nil ............... .direct(partIndex)   (parts 1+)
//   nil, Monterey+, partCount > 1 .. .direct(0)           (multi-part part 0)
//   nil, single-part / pre-Monterey  bare guid or closest-selectable fallback
func resolveMessageCellResolution(
    partIndex: Int?,
    partCount: Int,
    targetPartExists: Bool,
    isMontereyOrUp: Bool,
    overlay: Bool
) -> MessageCellResolution {
    if partIndex != nil, !targetPartExists {
        return .partNotFound
    }

    // The platform strips the `_0` suffix from part 0, so a bare GUID on a genuinely
    // multi-part message is addressed explicitly as part 0; single-part keeps the bare GUID.
    let directPartIndex: Int? = if partIndex != nil {
        partIndex
    } else if isMontereyOrUp, partCount > 1, targetPartExists {
        0
    } else {
        nil
    }

    if overlay || partCount == 0 || directPartIndex != nil {
        return .direct(partIndex: directPartIndex)
    }

    return targetPartExists ? .closestSelectable : .partNotFound
}

extension MessagesController {
    func resolveMessageCell(
        threadID _: String,
        messageGUID: String,
        partIndex: Int?,
        allowOverlay: Bool = true
    ) throws -> MessageCell {
        let guid = GUID<Message>(stringLiteral: messageGUID)

        guard let (message, chatGUID) = try db.message(with: guid, withAttachments: false) else {
            throw ErrorMessage("Could not find message \(messageGUID)")
        }

        let cellID: String? = isSonomaOrUp ? nil : message.balloonBundleID
        let isReply: Bool = message.threadOriginatorGUID != nil
        let overlay: Bool = allowOverlay && isMontereyOrUp && !isReply
        let targetPartIndex = partIndex ?? 0
        let targetPart = message.parts.first { $0.index.rawValue == targetPartIndex }

        switch resolveMessageCellResolution(
            partIndex: partIndex,
            partCount: message.parts.count,
            targetPartExists: targetPart != nil,
            isMontereyOrUp: isMontereyOrUp,
            overlay: overlay
        ) {
        case .partNotFound:
            throw ErrorMessage("Could not find the target part")

        case let .direct(directPartIndex):
            return MessageCell(
                messageGUID: messageGUID,
                partIndex: directPartIndex,
                axOffset: 0,
                cellID: cellID,
                cellRole: nil,
                overlay: overlay
            )

        case .closestSelectable:
            guard let targetPart else {
                throw ErrorMessage("Could not find the target part")
            }
            guard let closest = try db.findClosestSelectablePart(from: targetPart, parentMessage: message, in: chatGUID) else {
                throw ErrorMessage("Could not resolve selectable message cell")
            }
            return MessageCell(
                messageGUID: closest.closestSelectable.parentMessageGUID.description,
                partIndex: nil,
                axOffset: closest.offsetFromTarget,
                cellID: cellID,
                cellRole: nil,
                overlay: false
            )
        }
    }
}
