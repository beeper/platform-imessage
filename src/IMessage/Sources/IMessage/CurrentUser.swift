import Foundation
import IMDatabase
import IMessageCore
import PlatformSDK

extension PlatformSDK.CurrentUser {
    static func fetch(from db: IMDatabase) throws -> Self {
        let logins = try db.accountLogins()
        let unprefixed = logins.map(mapAccountLogin).compactMap(\.nonEmpty)

        return Self(
            id: unprefixed.first ?? "default",
            displayText: unprefixed.joined(separator: ", "),
            email: firstLoginValue(withPrefix: "E:", in: logins),
            phoneNumber: firstLoginValue(withPrefix: "P:", in: logins)
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

    private static func firstLoginValue(withPrefix prefix: String, in logins: [String]) -> String? {
        logins.first { $0.hasPrefix(prefix) }
            .map(mapAccountLogin)
            .flatMap(\.nonEmpty)
    }
}
