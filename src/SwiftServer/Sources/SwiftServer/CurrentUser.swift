import Foundation
import IMDatabase
import SwiftServerFoundation

struct CurrentUser: Encodable, Sendable {
    var id: String
    var displayText: String
    var email: String?
    var phoneNumber: String?

    static func fetch(from db: IMDatabase) throws -> Self {
        let logins = try db.accountLogins()
        let unprefixed = logins.map(mapAccountLogin).compactMap(\.nonEmpty)

        return CurrentUser(
            id: unprefixed.first ?? "default",
            displayText: unprefixed.joined(separator: ", "),
            email: firstLoginValue(withPrefix: "E:", in: logins),
            phoneNumber: firstLoginValue(withPrefix: "P:", in: logins)
        )
    }

    func hashed() -> Self {
        var currentUser = self
        currentUser.id = Hasher.participant.tokenizeRemembering(pii: id)
        return currentUser
    }

    private static func firstLoginValue(withPrefix prefix: String, in logins: [String]) -> String? {
        logins.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
            .flatMap(\.nonEmpty)
    }
}
