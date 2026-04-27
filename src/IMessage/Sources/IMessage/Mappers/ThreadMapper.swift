import Foundation
import IMDatabase
import IMessageCore

enum ThreadMapper {
    struct PollingCursor {
        var maxRowID: Int
        var maxDateReadNanoseconds: Int
    }

    struct Context {
        var handleRowsByChatRowID: [Int: [MappedHandleRow]]
        var latestMessagesByChatGUID: [String: [PlatformSDK.Message]]
        var unreadCounts: [Int: Int]
        var dndState: Set<String>
        var currentUser: CurrentUser
        var accountID: String
    }

    static func pollingCursor(from latestMessageRows: [MappedMessageRow]) -> PollingCursor? {
        guard !latestMessageRows.isEmpty else {
            return nil
        }
        let (maxRowID, maxDateReadNanoseconds) = latestMessageRows.reduce(into: (0, 0)) { result, row in
            result.0 = max(result.0, row.rowID)
            result.1 = max(result.1, row.dateRead ?? 0)
        }
        return PollingCursor(maxRowID: maxRowID, maxDateReadNanoseconds: maxDateReadNanoseconds)
    }

    static func mapThread(_ chat: MappedChatRow, context: Context) throws -> PlatformSDK.Thread {
        let guid = chat.guid
        let handleRows = context.handleRowsByChatRowID[chat.rowID] ?? []
        let messages = context.latestMessagesByChatGUID[guid] ?? []
        let selfID = chat.lastAddressedHandle.flatMap(\.nonEmpty)
            ?? chat.accountLogin.map(mapAccountLogin).flatMap(\.nonEmpty)
            ?? context.currentUser.id
        let firstParticipantID = handleRows.first?.participantID

        let chatDisplayName = chat.displayName
        var participants = handleRows.compactMap { mapParticipant($0, chatDisplayName: chatDisplayName) }
        if context.currentUser.id != firstParticipantID {
            participants.append(mapSelfParticipant(selfID: selfID, currentUserID: context.currentUser.id))
        }

        let isGroup = chat.roomName?.isEmpty == false
        let isReadOnly = chat.state == 0 && chat.properties != nil
        let props = propertyListDictionary(chat.properties)
        let unreadCount = context.unreadCounts[chat.rowID] ?? 0
        // Mirrors Poller+Unreads.swift. Desktop computes unread state from
        // `isMarkedUnread || unreadCount > 0`.
        let isUnread = unreadCount > 0

        return PlatformSDK.Thread(
            id: Hasher.thread.tokenizeRemembering(pii: guid),
            // Works around PAS's "map missing" behavior where the folder name
            // can otherwise be filled with the thread ID.
            folderName: "normal",
            title: chat.displayName,
            isUnread: isUnread,
            isReadOnly: isReadOnly,
            isPinned: false,
            mutedUntil: context.dndState.contains(isGroup ? (chat.groupID ?? "") : (chat.chatIdentifier ?? "")) ? "forever" : nil,
            type: isGroup ? .group : .single,
            timestamp: appleDateMilliseconds(chat.msgDate),
            imgURL: chatPhotoURL(props: props, accountID: context.accountID),
            messages: PlatformSDK.Paginated(items: messages, hasMore: true),
            participants: PlatformSDK.Paginated(items: participants, hasMore: false),
            extra: compactDictionary([
                "isSMS": (guid.hasPrefix("SMS;") || guid.hasPrefix("RCS;")) ? true : nil,
            ]),
            original: Preferences.stripInternalFields ? nil : (try? encodeJSON([chat.object, handleRows.objects])) ?? "",
            unreadCount: unreadCount,
            isMarkedUnread: isUnread,
            lastReadMessageSortKey: appleDateMilliseconds(chat.lastReadMessageTimestamp),
            isLowPriority: false
        )
    }

    private static func mapParticipant(_ row: MappedHandleRow, chatDisplayName: String?) -> PlatformSDK.Participant? {
        guard let id = row.participantID, !id.isEmpty else {
            return nil
        }
        let uncanonicalizedID = row.uncanonicalizedID
        let isPhone = isPhoneLike(id)
        let participantID = isPhone ? id : (uncanonicalizedID ?? id)
        let fields = participantFields(id: id, uncanonicalizedID: uncanonicalizedID, chatDisplayName: chatDisplayName)
        return PlatformSDK.Participant(user: PlatformSDK.User(
            id: Hasher.participant.tokenizeRemembering(pii: participantID),
            username: fields.username,
            phoneNumber: fields.phoneNumber,
            email: fields.email,
            fullName: fields.fullName
        ))
    }

    private static func mapSelfParticipant(selfID: String, currentUserID: String) -> PlatformSDK.Participant {
        let fields = participantFields(id: selfID, uncanonicalizedID: nil, chatDisplayName: nil)
        return PlatformSDK.Participant(user: PlatformSDK.User(
            id: Hasher.participant.tokenizeRemembering(pii: currentUserID),
            username: fields.username,
            phoneNumber: fields.phoneNumber,
            email: fields.email,
            fullName: fields.fullName,
            isSelf: true
        ))
    }

    private static func isPhoneLike(_ id: String) -> Bool {
        !id.hasPrefix("urn:") && !id.contains("@") && id.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private static func participantFields(
        id: String,
        uncanonicalizedID: String?,
        chatDisplayName: String?
    ) -> (username: String?, phoneNumber: String?, email: String?, fullName: String?) {
        if id.hasPrefix("urn:") { return (nil, nil, nil, chatDisplayName) }
        if id.contains("@") { return (nil, nil, id, nil) }
        if id.rangeOfCharacter(from: .decimalDigits) != nil { return (nil, id, nil, nil) }
        // iMessage can canonicalize SMS shortcodes with suffixes like
        // `(smsft_rm)` or `(smsft)`. Prefer the raw ID for sender-ID heuristics.
        let idPreferringUncanonicalized = uncanonicalizedID ?? id
        if likelyAlphanumericSenderID(idPreferringUncanonicalized) {
            // Use `username` to avoid first/last-name splitting and preserve
            // the sender ID as-is.
            return (idPreferringUncanonicalized, nil, nil, nil)
        }
        return (nil, nil, nil, nil)
    }

    private static let numbersAndSymbolsRegex = try! NSRegularExpression(pattern: #"^[\d\s+\-()]+$"#)
    private static let alphanumericSenderIDRegex = try! NSRegularExpression(pattern: #"^[\da-zA-Z .&_/-]{1,11}$"#)

    private static func likelyAlphanumericSenderID(_ id: String) -> Bool {
        !id.matches(against: numbersAndSymbolsRegex)
            && id.matches(against: alphanumericSenderIDRegex)
    }

    private static func chatPhotoURL(props: JSONObject?, accountID: String) -> String? {
        // `chat.properties` is a bplist; group chats may store a groupPhotoGuid
        // that resolves via the thread-image asset route.
        guard let groupPhotoGuid = props?["groupPhotoGuid"] as? String else {
            return nil
        }
        return "asset://\(accountID)/thread-image/\(groupPhotoGuid)"
    }

    private static func propertyListDictionary(_ data: Data?) -> JSONObject? {
        guard let data,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? JSONObject else {
            return nil
        }
        return plist
    }
}
