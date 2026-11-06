import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

private let recentHandleWindowNanoseconds: Int64 = 90 * 24 * 60 * 60 * 1_000_000_000

extension PlatformSDK.CurrentUser {
    static func fetch(from db: IMDatabase) throws -> Self {
        let logins = try db.accountLogins()
        let unprefixed = logins.map(mapAccountLogin).compactMap(\.nonEmpty)
        let recentHandles = try db.recentDestinationCallerIDs(withinNanoseconds: recentHandleWindowNanoseconds)
        let activeLogins = loginsInUse(logins, recentHandles: recentHandles)

        return Self(
            id: unprefixed.first ?? "default",
            displayText: activeLogins.map(mapAccountLogin).compactMap(\.nonEmpty).joined(separator: ", "),
            email: firstLoginValue(withPrefix: "E:", in: activeLogins),
            phoneNumber: firstLoginValue(withPrefix: "P:", in: activeLogins)
        )
    }

    func hashed() -> Self {
        Self(
            id: Hasher.participant.tokenizeRemembering(pii: id),
            displayText: displayText,
            email: email,
            phoneNumber: phoneNumber
        )
    }

    private static func loginsInUse(_ logins: [String], recentHandles: [String]) -> [String] {
        let recent = Set(recentHandles.map(handleKey).filter { !$0.isEmpty })
        let inUse = logins.filter { recent.contains(handleKey(mapAccountLogin($0))) }
        return inUse.isEmpty ? logins : inUse
    }

    private static func handleKey(_ handle: String) -> String {
        handle.contains("@") ? handle.lowercased() : handle.filter(\.isNumber)
    }

    private static func firstLoginValue(withPrefix prefix: String, in logins: [String]) -> String? {
        logins.first { $0.hasPrefix(prefix) }
            .map(mapAccountLogin)
            .flatMap(\.nonEmpty)
    }
}
