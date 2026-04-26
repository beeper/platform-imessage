import Foundation
import SwiftServerFoundation

enum ThreadMapper {
    struct PollingCursor {
        var maxRowID: Int
        var maxDateReadNanoseconds: Int
    }

    struct Context {
        var handleRowsByChatRowID: [Int: [JSONObject]]
        var latestMessagesByChatGUID: [String: [JSONObject]]
        var unreadCounts: [Int: Int]
        var dndState: Set<String>
        var currentUserID: String
        var accountID: String
    }

    static func mapAndHashThread(_ chat: JSONObject, context: Context) throws -> JSONObject {
        hashThread(try mapThread(chat, context: context))
    }

    static func pollingCursor(from latestMessageRows: [JSONObject]) -> PollingCursor? {
        guard !latestMessageRows.isEmpty else {
            return nil
        }
        let (maxRowID, maxDateReadNanoseconds) = latestMessageRows.reduce(into: (0, 0)) { result, row in
            result.0 = max(result.0, row.int("ROWID") ?? 0)
            // Guard against bogus read dates that overflow Int64 — the source
            // of these is unknown but they'd poison the polling cursor.
            guard (row.string("dateReadString") ?? "0") < int64MaxString else {
                return
            }
            result.1 = max(result.1, row.int("date_read") ?? 0)
        }
        return PollingCursor(maxRowID: maxRowID, maxDateReadNanoseconds: maxDateReadNanoseconds)
    }

    private static let int64MaxString = String(Int.max)

    private static func mapThread(_ chat: JSONObject, context: Context) throws -> JSONObject {
        let guid = chat.string("guid") ?? ""
        let handleRows = context.handleRowsByChatRowID[chat.int("ROWID") ?? -1] ?? []
        let messages = context.latestMessagesByChatGUID[guid] ?? []
        let selfID = chat.string("last_addressed_handle") ?? chat.string("account_login").map(mapAccountLogin) ?? context.currentUserID
        let firstParticipantID = handleRows.first?.string("participantID")

        let chatDisplayName = chat.string("display_name")
        var participants = handleRows.compactMap { mapParticipant($0, chatDisplayName: chatDisplayName) }
        if context.currentUserID != firstParticipantID {
            var selfParticipant = mapParticipant(["participantID": selfID], chatDisplayName: nil) ?? [:]
            selfParticipant["id"] = context.currentUserID
            selfParticipant["isSelf"] = true
            participants.append(selfParticipant)
        }

        let isGroup = chat.string("room_name")?.isEmpty == false
        let isReadOnly = chat.int("state") == 0 && chat.hasValue("properties")
        let props = propertyListDictionary(chat.dataURI("properties"))
        let unreadCount = context.unreadCounts[chat.int("ROWID") ?? -1] ?? 0

        var thread = compactDictionary([
            "id": guid,
            "title": chat.string("display_name"),
            "imgURL": chatPhotoURL(props: props, accountID: context.accountID),
            "mutedUntil": context.dndState.contains(isGroup ? (chat.string("group_id") ?? "") : (chat.string("chat_identifier") ?? "")) ? "forever" : nil,
            "type": isGroup ? "group" : "single",
            "isReadOnly": isReadOnly,
            // This mirrors Poller+Unreads.swift. Desktop computes unread state
            // from `isMarkedUnread || unreadCount > 0`.
            "unreadCount": unreadCount,
            "isMarkedUnread": unreadCount > 0,
            "lastReadMessageSortKey": appleDateMilliseconds(chat.string("dateLastMessageReadString")),
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
            "timestamp": appleDateMilliseconds(chat.string("msgDateString")),
            "extra": compactDictionary([
                "isSMS": (guid.hasPrefix("SMS;") || guid.hasPrefix("RCS;")) ? true : nil,
            ]),
            "isPinned": false,
            "isLowPriority": false,
        ])

        if !stripInternalFields {
            thread["_original"] = (try? PlatformAPI.encodeJSON([chat, handleRows])) ?? ""
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

    private static func mapParticipant(_ row: JSONObject, chatDisplayName: String?) -> JSONObject? {
        guard let id = row.string("participantID"), !id.isEmpty else {
            return nil
        }

        var participant: JSONObject = ["id": id]
        let isEmail = id.contains("@")
        let isBusiness = id.hasPrefix("urn:")
        let isPhone = !isBusiness && !isEmail && id.rangeOfCharacter(from: .decimalDigits) != nil
        let uncanonicalizedID = row.string("uncanonicalized_id")
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
