import Foundation

extension PlatformSDK {
    @PlatformSDKJSONObject
    public struct User: JSONObjectConvertible {
        public let id: UserID
        public let username: String?
        public let phoneNumber: String?
        public let email: String?
        public let fullName: String?
        public let nickname: String?
        public let imgURL: String?
        public let isVerified: Bool?
        public let cannotMessage: Bool?
        public let isSelf: Bool?
        public let social: JSONObject?

        public init(
            id: UserID,
            username: String? = nil,
            phoneNumber: String? = nil,
            email: String? = nil,
            fullName: String? = nil,
            nickname: String? = nil,
            imgURL: String? = nil,
            isVerified: Bool? = nil,
            cannotMessage: Bool? = nil,
            isSelf: Bool? = nil,
            social: JSONObject? = nil
        ) {
            self.id = id
            self.username = username
            self.phoneNumber = phoneNumber
            self.email = email
            self.fullName = fullName
            self.nickname = nickname
            self.imgURL = imgURL
            self.isVerified = isVerified
            self.cannotMessage = cannotMessage
            self.isSelf = isSelf
            self.social = social
        }

        public init(id: UserID, displayText: String? = nil, email: String? = nil, phoneNumber: String? = nil) {
            self.init(id: id, phoneNumber: phoneNumber, email: email, fullName: displayText, isSelf: true)
        }

    }

    @PlatformSDKJSONObject
    public struct CurrentUser: JSONObjectConvertible, Sendable {
        public let id: UserID
        public let displayText: String?
        public let email: String?
        public let phoneNumber: String?

        public init(id: UserID, displayText: String?, email: String?, phoneNumber: String?) {
            self.id = id
            self.displayText = displayText
            self.email = email
            self.phoneNumber = phoneNumber
        }

    }

    public struct Participant: JSONObjectConvertible {
        public let user: User
        public let addedBy: UserID?
        public let isAdmin: Bool?
        public let hasExited: Bool?

        public init(user: User, addedBy: UserID? = nil, isAdmin: Bool? = nil, hasExited: Bool? = nil) {
            self.user = user
            self.addedBy = addedBy
            self.isAdmin = isAdmin
            self.hasExited = hasExited
        }

        public var jsonObject: JSONObject {
            var object = user.jsonObject
            object.merge(compactDictionary([
                "addedBy": addedBy,
                "isAdmin": isAdmin,
                "hasExited": hasExited,
            ])) { _, new in new }
            return object
        }
    }
}
