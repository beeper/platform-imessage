import Foundation

// MARK: - Filter Category Bitmask

public extension Chat {
    /// Bitmask values from the `is_filtered` column in chat.db.
    /// These indicate how Apple's Message Filter extensions have categorized the chat.
    struct FilterCategory: OptionSet, Sendable, Hashable {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        /// Chat is from an unknown sender (not in contacts)
        public static let unknownSender = FilterCategory(rawValue: 1 << 0)

        /// Chat contains promotional messages
        public static let promotion = FilterCategory(rawValue: 1 << 2)

        /// Chat contains transactional messages (banks, receipts, etc.)
        public static let transaction = FilterCategory(rawValue: 1 << 5)

        /// No filtering applied - appears in primary inbox
        public static let none: FilterCategory = []
    }
}

// MARK: - SMS Category (from properties blob)

public extension Chat {
    /// Main SMS filter category from the `properties` blob.
    enum SMSCategory: Int, Sendable {
        case allow = 0
        case junk = 1
        case unknown2 = 2
        case filtered = 3  // Business/filtered messages
    }
}

// MARK: - SMS Sub-Category (from properties blob)

public extension Chat {
    /// Sub-category mapping to Apple's `ILMessageFilterSubAction` enum.
    /// These provide more granular classification within Transaction/Promotion categories.
    enum SMSSubCategory: Int, Sendable {
        case none = 0
        case promotionalOthers = 1
        case transactionalFinance = 2
        case transactionalOrders = 3
        case transactionalPublicServices = 4
        case transactionalHealth = 5
        case transactionalWeather = 6
        case transactionalCarrier = 7
        case transactionalRewards = 8
        case transactionalReminders = 9
        case promotionalOffers = 10
        case promotionalCoupons = 11
    }
}

// MARK: - Chat Properties

public extension Chat {
    /// Parsed contents of the `properties` blob in the chat table.
    struct Properties: Sendable {
        public var smsCategory: SMSCategory?
        public var smsSubCategory: SMSSubCategory?
        public var wasDetectedAsSMSSpam: Bool
        public var hasOTPCode: Bool
        public var isMergedBusinessThread: Bool
        public var smsSpamExtensionName: String?

        public init(blob: Data) throws {
            var format = PropertyListSerialization.PropertyListFormat.binary
            let plist = try PropertyListSerialization.propertyList(from: blob, options: [], format: &format)
            guard let dict = plist as? [String: Any] else {
                throw ChatPropertiesError.notADictionary
            }

            if let categoryRaw = dict["SMSCategory"] as? Int {
                smsCategory = SMSCategory(rawValue: categoryRaw)
            } else {
                smsCategory = nil
            }

            if let subCategoryRaw = dict["SMSSubCategory"] as? Int {
                smsSubCategory = SMSSubCategory(rawValue: subCategoryRaw)
            } else {
                smsSubCategory = nil
            }

            wasDetectedAsSMSSpam = dict["wasDetectedAsSMSSpam"] as? Bool ?? false
            hasOTPCode = dict["hasOTPCode"] as? Bool ?? false
            isMergedBusinessThread = dict["isMergedBusinessThread"] as? Bool ?? false
            smsSpamExtensionName = dict["smsSpamExtensionName"] as? String
        }

        public init() {
            smsCategory = nil
            smsSubCategory = nil
            wasDetectedAsSMSSpam = false
            hasOTPCode = false
            isMergedBusinessThread = false
            smsSpamExtensionName = nil
        }
    }

    enum ChatPropertiesError: Error {
        case notADictionary
    }
}

// MARK: - Convenience Bucket Classification

public extension Chat {
    /// High-level message bucket for UI display (similar to Beeper's filtering UI).
    enum Bucket: String, Sendable, CaseIterable {
        case primary
        case unknownSenders
        case transactions
        case promotions
        case spam
    }

    /// Determines which bucket this chat belongs to based on filtering data.
    var bucket: Bucket {
        // Check spam first
        if properties?.wasDetectedAsSMSSpam == true {
            return .spam
        }

        // Check transactions (higher priority than promotions)
        if filterCategory.contains(.transaction) {
            return .transactions
        }
        if let subCategory = properties?.smsSubCategory {
            switch subCategory {
            case .transactionalFinance, .transactionalOrders, .transactionalPublicServices,
                 .transactionalHealth, .transactionalWeather, .transactionalCarrier,
                 .transactionalRewards, .transactionalReminders:
                return .transactions
            default:
                break
            }
        }

        // Check promotions
        if filterCategory.contains(.promotion) {
            return .promotions
        }
        if let subCategory = properties?.smsSubCategory {
            switch subCategory {
            case .promotionalOthers, .promotionalOffers, .promotionalCoupons:
                return .promotions
            default:
                break
            }
        }

        // Check unknown senders
        if filterCategory.contains(.unknownSender) {
            return .unknownSenders
        }

        return .primary
    }
}
