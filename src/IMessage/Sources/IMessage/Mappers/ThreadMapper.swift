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
        var latestMessagesByChatGUID: [String: [JSONObject]]
        var unreadCounts: [Int: Int]
        var dndState: Set<String>
        var currentUser: CurrentUser
        var accountID: String
    }

    static func mapAndHashThread(_ chat: MappedChatRow, context: Context) throws -> JSONObject {
        hashThread(try mapThread(chat, context: context))
    }

    static func pollingCursor(from latestMessageRows: [MappedMessageRow]) -> PollingCursor? {
        guard !latestMessageRows.isEmpty else {
            return nil
        }
        let (maxRowID, maxDateReadNanoseconds) = latestMessageRows.reduce(into: (0, 0)) { result, row in
            result.0 = max(result.0, row.rowID)
            // Guard against bogus read dates that overflow Int64 — the source
            // of these is unknown but they'd poison the polling cursor.
            guard row.dateReadString < int64MaxString else {
                return
            }
            result.1 = max(result.1, row.dateRead ?? 0)
        }
        return PollingCursor(maxRowID: maxRowID, maxDateReadNanoseconds: maxDateReadNanoseconds)
    }

    private static let int64MaxString = String(Int.max)

    private static func mapThread(_ chat: MappedChatRow, context: Context) throws -> JSONObject {
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

        var thread = compactDictionary([
            "id": guid,
            "title": chat.displayName,
            "imgURL": chatPhotoURL(props: props, accountID: context.accountID),
            "mutedUntil": context.dndState.contains(isGroup ? (chat.groupID ?? "") : (chat.chatIdentifier ?? "")) ? "forever" : nil,
            "type": isGroup ? "group" : "single",
            "isReadOnly": isReadOnly,
            // This mirrors Poller+Unreads.swift. Desktop computes unread state
            // from `isMarkedUnread || unreadCount > 0`.
            "unreadCount": unreadCount,
            "isMarkedUnread": unreadCount > 0,
            "lastReadMessageSortKey": appleDateMilliseconds(chat.dateLastMessageReadString),
            "messages": [
                "hasMore": true,
                "items": messages,
            ],
            "participants": [
                "hasMore": false,
                "items": participants,
            ],
            // Works around PAS's "map missing" behavior where the folder name
            // can otherwise be filled with the thread ID.
            "folderName": "normal",
            "timestamp": appleDateMilliseconds(chat.msgDateString),
            "extra": compactDictionary([
                "isSMS": (guid.hasPrefix("SMS;") || guid.hasPrefix("RCS;")) ? true : nil,
            ]),
            "isPinned": false,
            "isLowPriority": false,
        ])

        if !Preferences.stripInternalFields {
            thread["_original"] = (try? encodeJSON([chat.object, handleRows.objects])) ?? ""
        }
        return thread
    }

    private static func hashThread(_ thread: JSONObject) -> JSONObject {
        var thread = thread
        if let id = thread.string("id") {
            thread["id"] = Hasher.thread.tokenizeRemembering(pii: id)
        }
        if var participants = thread.dictionary("participants"),
           let items = participants["items"] as? [JSONObject] {
            participants["items"] = items.map(hashParticipant)
            thread["participants"] = participants
        }
        return thread
    }

    private static func hashParticipant(_ participant: JSONObject) -> JSONObject {
        var participant = participant
        if let id = participant.string("id") {
            participant["id"] = Hasher.participant.tokenizeRemembering(pii: id)
        }
        return participant
    }

    private static func mapParticipant(_ row: MappedHandleRow, chatDisplayName: String?) -> JSONObject? {
        guard let id = row.participantID, !id.isEmpty else {
            return nil
        }

        var participant: JSONObject = ["id": id]
        let isEmail = id.contains("@")
        let isBusiness = id.hasPrefix("urn:")
        let isPhone = !isBusiness && !isEmail && id.rangeOfCharacter(from: .decimalDigits) != nil
        let uncanonicalizedID = row.uncanonicalizedID
        // iMessage can canonicalize SMS shortcodes with suffixes like
        // `(smsft_rm)` or `(smsft)`. Prefer the raw ID for sender-ID heuristics.
        let idPreferringUncanonicalized = uncanonicalizedID ?? id

        if isBusiness {
            participant["fullName"] = chatDisplayName
        } else if isEmail {
            participant["email"] = id
        } else if isPhone {
            participant["phoneNumber"] = id
        } else if likelyAlphanumericSenderID(idPreferringUncanonicalized) {
            // Use `username` to avoid first/last-name splitting and preserve
            // the sender ID as-is.
            participant["username"] = idPreferringUncanonicalized
        }

        if !isPhone, let uncanonicalizedID {
            participant["id"] = uncanonicalizedID
        }
        return participant
    }

    private static func mapSelfParticipant(selfID: String, currentUserID: String) -> JSONObject {
        var participant = mapParticipant(
            MappedHandleRow(chatID: nil, participantID: selfID, uncanonicalizedID: nil),
            chatDisplayName: nil
        ) ?? [:]
        participant["id"] = currentUserID
        participant["isSelf"] = true
        return participant
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
