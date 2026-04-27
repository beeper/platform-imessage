import Foundation

extension PlatformSDK {
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

        public init(jsonObject: JSONObject) throws {
            id = try PlatformSDKJSON.requiredString(jsonObject, "id", type: "User")
            username = jsonObject.string("username")
            phoneNumber = jsonObject.string("phoneNumber")
            email = jsonObject.string("email")
            fullName = jsonObject.string("fullName")
            nickname = jsonObject.string("nickname")
            imgURL = jsonObject.string("imgURL")
            isVerified = jsonObject.bool("isVerified")
            cannotMessage = jsonObject.bool("cannotMessage")
            isSelf = jsonObject.bool("isSelf")
            social = jsonObject.dictionary("social")
        }

        public init(id: UserID, displayText: String? = nil, email: String? = nil, phoneNumber: String? = nil) {
            self.id = id
            username = nil
            self.phoneNumber = phoneNumber
            self.email = email
            fullName = displayText
            nickname = nil
            imgURL = nil
            isVerified = nil
            cannotMessage = nil
            isSelf = true
            social = nil
        }

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "username": username,
                "phoneNumber": phoneNumber,
                "email": email,
                "fullName": fullName,
                "nickname": nickname,
                "imgURL": imgURL,
                "isVerified": isVerified,
                "cannotMessage": cannotMessage,
                "isSelf": isSelf,
                "social": social,
            ])
        }
    }

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

        public var jsonObject: JSONObject {
            compactDictionary([
                "id": id,
                "displayText": displayText,
                "email": email,
                "phoneNumber": phoneNumber,
            ])
        }
    }

    public struct Participant: JSONObjectConvertible {
        public let user: User
        public let addedBy: UserID?
        public let isAdmin: Bool?
        public let hasExited: Bool?

        public init(jsonObject: JSONObject) throws {
            user = try User(jsonObject: jsonObject)
            addedBy = jsonObject.string("addedBy")
            isAdmin = jsonObject.bool("isAdmin")
            hasExited = jsonObject.bool("hasExited")
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
