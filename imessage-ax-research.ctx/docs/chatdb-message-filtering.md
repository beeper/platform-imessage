---
id: chatdb-message-filtering
title: chat.db Message Filtering & Categorization
created: 2026-01-25
summary: How macOS/iOS stores message categories (transactions, promotions, spam, unknown senders) in chat.db
modified: 2026-01-25
---

# chat.db Message Filtering & Categorization

## Overview

macOS/iOS already stores message categorization data in `chat.db`. This enables the Beeper-style message bucketing (Transactions, Promotions, Spam, Unknown Senders) without ML/heuristics - Apple's Message Filter extensions have already done the classification.

## Key Database Fields

### chat.is_filtered (Bitmask)

The `is_filtered` column uses a bitmask to indicate message categories:

| Bit | Value | Category |
|-----|-------|----------|
| 0   | 1     | Unknown Sender (not in contacts) |
| 1   | 2     | (Unknown - seen with bit 0) |
| 2   | 4     | Promotion |
| 4   | 16    | (Unknown - seen with Transaction) |
| 5   | 32    | Transaction |
| 6   | 64    | (Unknown - seen with Promotion) |

Common combinations observed:
- `1`: Unknown sender only
- `3`: Unknown sender + bit 1
- `4`: Promotion only
- `36`: Transaction + Promotion (32+4)
- `52`: Transaction + Promotion + bit 4 (32+16+4)
- `68`: Promotion + bit 6 (64+4)

### chat.properties (Plist Blob)

The `properties` column contains a binary plist with detailed categorization:

| Field | Type | Description |
|-------|------|-------------|
| `SMSCategory` | Int | Main filter category (0=allow?, 3=filtered/business) |
| `SMSSubCategory` | Int | Maps to Apple's ILMessageFilterSubAction |
| `wasDetectedAsSMSSpam` | Bool | Spam detection flag |
| `hasOTPCode` | Bool | Contains one-time password |
| `isMergedBusinessThread` | Bool | Business message indicator |
| `smsSpamExtensionName` | String | Filter extension name (e.g., "Text Message Filter") |
| `timeSensitiveDate` | Date | When time-sensitive status was set |

### chat.is_pending_review

Boolean indicating if the chat needs manual review (appears in "Unknown Senders" that need verification).

### chat.is_blackholed

Boolean indicating if the chat is blocked/silenced.

### message.is_spam

Per-message spam flag (INTEGER DEFAULT 0). Note: In testing, all messages had is_spam=0.

## SMSSubCategory Mapping

Based on observed data and Apple's `ILMessageFilterSubAction` enum:

| Value | Observed Senders | Likely Category |
|-------|------------------|-----------------|
| 0 | Various promotional | Promotional (generic) |
| 2 | KOTAKB (Kotak Bank) | Transactional Finance |
| 3 | AIRBIL (Airtel Bills) | Transactional Orders |
| 4 | GSTIND (GST India), KOTAKB | Transactional Public Services |

### Apple's ILMessageFilterSubAction Enum (iOS 16+)

**Transactional Sub-Actions:**
- `.transactionalFinance`
- `.transactionalOrders`
- `.transactionalHealth`
- `.transactionalPublicServices`
- `.transactionalWeather`
- `.transactionalRewards`
- `.transactionalCarrier`
- `.transactionalReminders`
- `.transactionalOthers`

**Promotional Sub-Actions:**
- `.promotionalOffers`
- `.promotionalCoupons`
- `.promotionalOthers`

## Parsing the Properties Blob

The `properties` column is a binary plist. To extract in Swift:

```swift
if let data = propertiesBlob,
   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
    let smsCategory = plist["SMSCategory"] as? Int
    let smsSubCategory = plist["SMSSubCategory"] as? Int
    let isSpam = plist["wasDetectedAsSMSSpam"] as? Bool ?? false
    let hasOTP = plist["hasOTPCode"] as? Bool ?? false
}
```

## Beeper Bucket Mapping

Suggested mapping to Beeper's UI buckets:

| Beeper Bucket | chat.db Condition |
|---------------|-------------------|
| Unknown Senders | `is_filtered & 1 \!= 0` |
| Transactions | `is_filtered & 32 \!= 0` OR `SMSSubCategory` in [2,3,4] |
| Promotions | `is_filtered & 4 \!= 0` AND NOT Transaction |
| Spam | `wasDetectedAsSMSSpam = true` OR `message.is_spam = 1` |
| Messages (Primary) | Everything else (`is_filtered = 0`) |

## References

See {@chatdb-filter-constants} for bitmask/category constant values.

External resources: {@chatdb-filtering-refs}
