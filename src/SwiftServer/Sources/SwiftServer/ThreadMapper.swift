import Foundation
import IMDatabase
import SwiftServerFoundation

enum ThreadMapper {
    struct Context {
        var accountID: String
        var currentUserID: String
        var handleRowsByChatRowID: [Int: [JSONObject]]
        var latestMessagesByChatGUID: [String: [JSONObject]]
        var unreadCounts: [Int: Int]
        var dndState: Set<String>
    }

    static func latestMessageRowsByChatGUID(chatRows: [JSONObject], db: IMDatabase) throws -> [String: JSONObject] {
        try chatRows.reduce(into: [:]) { result, chatRow in
            guard let guid = chatRow.string("guid") else {
                return
            }
            result[guid] = try db.mappedMessageRows(in: guid, cursor: nil, direction: nil, limit: 1).first
        }
    }

    static func context(
        chatRows: [JSONObject],
        latestMessageRowsByChatGUID: [String: JSONObject],
        db: IMDatabase,
        currentUserID: String,
        accountID: String
    ) throws -> Context {
        let chatRowIDs = chatRows.compactMap { $0.int("ROWID") }
        let participantRows = try db.mappedThreadParticipantRows(chatRowIDs: chatRowIDs)
        let unreadCounts = try db.mappedUnreadCounts()
        let dndState = Set((Defaults.getDNDList() ?? [:]).compactMap { key, value in
            value == Int(Date.distantFuture.timeIntervalSince1970) ? key : nil
        })

        var latestMessagesByChatGUID = [String: [JSONObject]]()
        for (guid, msgRow) in latestMessageRowsByChatGUID {
            latestMessagesByChatGUID[guid] = try PlatformAPI.mapAndHashMessages(
                msgRows: [msgRow],
                db: db,
                threadID: guid,
                currentUserID: currentUserID,
                accountID: accountID
            )
        }

        return Context(
            accountID: accountID,
            currentUserID: currentUserID,
            handleRowsByChatRowID: participantRows,
            latestMessagesByChatGUID: latestMessagesByChatGUID,
            unreadCounts: unreadCounts,
            dndState: dndState
        )
    }

    static func mapAndHashThread(_ chat: JSONObject, context: Context) throws -> JSONObject {
        hashThread(try mapThread(chat, context: context))
    }

    static func pollingCursor(from latestMessageRows: [JSONObject]) -> JSONObject? {
        guard !latestMessageRows.isEmpty else {
            return nil
        }
        let maxRowID = latestMessageRows.compactMap { $0.int("ROWID") }.max() ?? 0
        let largestSigned64BitInt = "9223372036854775807"
        let maxDateRead = latestMessageRows.map { row -> Int in
            guard (row.string("dateReadString") ?? "0") < largestSigned64BitInt else {
                return 0
            }
            return row.int("date_read") ?? 0
        }.max() ?? 0
        return [
            "maxRowID": maxRowID,
            "maxDateRead": maxDateRead,
        ]
    }

    private static func mapThread(_ chat: JSONObject, context: Context) throws -> JSONObject {
        let guid = chat.string("guid") ?? ""
        let handleRows = context.handleRowsByChatRowID[chat.int("ROWID") ?? -1] ?? []
        let messages = context.latestMessagesByChatGUID[guid] ?? []
        let selfID = chat.string("last_addressed_handle") ?? mapAccountLogin(chat.string("account_login")) ?? context.currentUserID
        let firstParticipantID = handleRows.first?.string("participantID")

        var participants = handleRows.compactMap { mapParticipant($0, chatDisplayName: chat.string("display_name")) }
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
        let range = NSRange(id.startIndex ..< id.endIndex, in: id)
        return numbersAndSymbolsRegex.firstMatch(in: id, range: range) == nil
            && alphanumericSenderIDRegex.firstMatch(in: id, range: range) != nil
    }

    private static func mapAccountLogin(_ accountLogin: String?) -> String? {
        guard let accountLogin else {
            return nil
        }
        if accountLogin.hasPrefix("E:") || accountLogin.hasPrefix("P:") {
            return String(accountLogin.dropFirst(2))
        }
        return accountLogin
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
