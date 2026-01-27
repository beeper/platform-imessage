---
id: chatdb-message-filtering
title: chat.db Message Filtering & Categorization
created: 2026-01-25
summary: How macOS/iOS stores message categories (transactions, promotions, spam, unknown senders) in chat.db
modified: 2026-01-26
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

## Implementation

The filtering has been implemented across the full stack:

### 1. Swift IMDatabase Layer

**File:** `SwiftServer/Sources/IMDatabase/Models/Chat+Filtering.swift`

```swift
// Bitmask OptionSet for is_filtered column
public struct FilterCategory: OptionSet, Sendable, Hashable {
    public static let unknownSender = FilterCategory(rawValue: 1 << 0)
    public static let promotion = FilterCategory(rawValue: 1 << 2)
    public static let transaction = FilterCategory(rawValue: 1 << 5)
}

// High-level bucket enum
public enum Bucket: String, Sendable, CaseIterable {
    case primary
    case unknownSenders
    case transactions
    case promotions
    case spam
}

// Computed property on Chat
var bucket: Bucket { /* checks spam → transactions → promotions → unknownSenders → primary */ }
```

**File:** `SwiftServer/Sources/IMDatabase/Models/Chat.swift`
- Added `filterCategory: FilterCategory`
- Added `isPendingReview: Bool`
- Added `properties: Properties?`

**File:** `SwiftServer/Sources/IMDatabase/Database/IMDatabase+Chats.swift`
- Updated SQL queries to fetch `is_filtered`, `is_pending_review`, `properties`
- Added `chatsByBucket()` and `chats(inBucket:)` convenience methods

### 2. platform-imessage TypeScript Layer

**File:** `src/types.ts`
```typescript
export type FilterBucket = 'primary' | 'unknownSenders' | 'transactions' | 'promotions' | 'spam'

export const FilterCategory = {
    UNKNOWN_SENDER: 1 << 0,  // 1
    PROMOTION: 1 << 2,       // 4
    TRANSACTION: 1 << 5,     // 32
} as const

export const SMSSubCategory = {
    TRANSACTIONAL_FINANCE: 2,
    TRANSACTIONAL_ORDERS: 3,
    TRANSACTIONAL_PUBLIC_SERVICES: 4,
    // ... etc
} as const
```

**File:** `src/mappers.ts`
- Added `computeFilterBucket(isFiltered, props)` function
- Updated `mapThread()` to include `filterBucket` in `thread.extra`

### 3. Beeper Desktop Layer

**File:** `src/common/enums.ts`
```typescript
export enum ThreadsFilter {
    // ... existing filters ...
    TRANSACTIONS = 'transactions',
    PROMOTIONS = 'promotions',
    SPAM = 'spam',
    UNKNOWN_SENDERS = 'unknown_senders',
}
```

**File:** `src/renderer/stores/ThreadStore.ts`
```typescript
@computed get filterBucket() {
    return this.extra?.filterBucket
}
```

**File:** `src/renderer/stores/WindowStateStore.ts`
```typescript
case ThreadsFilter.TRANSACTIONS: return t.filterBucket === 'transactions'
case ThreadsFilter.PROMOTIONS: return t.filterBucket === 'promotions'
case ThreadsFilter.SPAM: return t.filterBucket === 'spam'
case ThreadsFilter.UNKNOWN_SENDERS: return t.filterBucket === 'unknownSenders'
```

**File:** `src/renderer/components/AccountFilters/AccountFilters.tsx`
- Added new filters to `VISIBLE_THREAD_FILTERS` array
- Added display names to `THREAD_FILTER_NAMES` record

## ⚠️ Uncertainty: Bitmask vs Suffix-Based Classification

**Status: Under Investigation**

Initial implementation used the `is_filtered` bitmask (e.g., `is_filtered & 4` for promotions), but this does NOT match what Messages.app displays. Investigation revealed:

### Observed Discrepancy

- **Beeper (bitmask-based)**: Shows 31+ promotions
- **Messages.app**: Shows only 8 promotions

### chat_identifier Suffix Pattern (More Accurate?)

The `chat_identifier` column contains a suffix that may be the actual categorization signal:

| Suffix | is_filtered | Apparent Bucket | Count (observed) |
|--------|-------------|-----------------|------------------|
| `(none)` | 0 | Primary | ~219 |
| `(none)` | 1 | Unknown Senders | ~5 |
| `(smsfp)` | 3 | **Promotions** | 8 |
| `(smsft)` | 4, 52, 68 | Transactions (generic) | ~34 |
| `(smsft_fi)` | 36 | Transactions (finance) | 3 |
| `(smsft_or)` | 52 | Transactions (orders) | ? |
| `(smsft_rm)` | 68 | Transactions (reminders) | ? |

Suffix meanings (speculative):
- `smsfp` = SMS Filtered Promotional
- `smsft` = SMS Filtered Transactional
- `smsft_fi` = SMS Filtered Transactional Finance
- `smsft_or` = SMS Filtered Transactional Orders
- `smsft_rm` = SMS Filtered Transactional Reminders

### Key Finding

`is_filtered = 3` (bits 0+1) correlates with `(smsfp)` suffix and matches Messages.app Promotions count.

The `is_filtered & 4` (bit 2) does NOT indicate promotions - those chats have `(smsft)` suffix and appear to be in Transactions.

### Next Steps

1. Use axdump to inspect Messages.app UI and verify actual bucket counts
2. Determine if suffix or bitmask is the authoritative signal
3. Update implementation accordingly

### Verification Results (2026-01-26)

**Method used:** Database query on `chat_identifier` suffix pattern

**Expected counts (from Messages.app):**
- Promotions: 8
- Transactions (Finance): 3
- Transactions (Orders): 5
- Transactions (Reminders): 2

**Database counts (by suffix, chats with messages):**

| Suffix | Count | Notes |
|--------|-------|-------|
| `(smsfp)` | 8 | ✓ Matches Messages Promotions |
| `(smsft)` | 34 | Generic transactions |
| `(smsft_fi)` | 3 | ✓ Matches Finance |
| `(smsft_or)` | 3 | ✗ Messages shows 5 |
| `(smsft_rm)` | 1 | ✗ Messages shows 2 |

**Discrepancy analysis:** Messages.app likely classifies some `(smsft)` (generic) chats into Orders/Reminders subcategories based on the `properties` plist (`SMSSubCategory` field), not just the suffix.

**Key insight:** The suffix is appended when the chat is created, but the `SMSSubCategory` can be updated by the Message Filter extension as new messages arrive. Messages.app may use `SMSSubCategory` for display, not just the suffix.

**Conclusion:** 
- For **Promotions**: Use `is_filtered = 3` or `(smsfp)` suffix (both work, 8 chats)
- For **Transactions**: The suffix alone is NOT reliable for subcategories. Need to check `properties.SMSSubCategory` for accurate Finance/Orders/Reminders breakdown.

### Open Questions

1. What is the exact mapping between `SMSSubCategory` values and transaction subcategories?
2. Does the suffix get updated when SMSSubCategory changes, or only when chat is first created?
3. Are there chats in `(smsft)` that should appear in Orders/Reminders based on their latest message's SMSSubCategory?

### Verified Counts via axdump (2026-01-26)

Successfully used axdump to switch Messages.app filters and count visible conversations:

| Bucket | Count | Verified |
|--------|-------|----------|
| Promotions | 8 | ✓ |
| Finance | 3 | ✓ |
| Orders | 5 | ✓ |
| Reminders | 2 | ✓ |

### Key Discovery: Chat Merging

Messages.app **merges** multiple chat.db entries with the same base sender name. For example:

**BLUDRT** appears in Orders because:
- `BLUDRT-S(smsft)`: SMSSubCategory=0 (generic)
- `BLUDRT-S(smsft_or)`: SMSSubCategory=3 (Orders) ← This wins

**OLACAB** appears in Reminders because:
- `OLACAB-S(smsft)`: SMSSubCategory=0
- `OLACAB-S(smsfp)`: SMSSubCategory=0 (Promotions suffix)
- `OLACAB-S(smsft_rm)`: SMSSubCategory=4 (Reminders) ← This wins

### Correct Classification Logic

Messages.app appears to:
1. Group chats by base sender name (before suffix)
2. For each group, use the **most specific** subcategory found across all variants
3. Suffix hierarchy: `smsft_*` (specific) > `smsft` (generic) > `smsfp` (promotional)

### Implementation Implications

To match Messages.app behavior, we need to:
1. **For Promotions**: Check `is_filtered = 3` OR `(smsfp)` suffix
2. **For Transactions subcategories**: Check `SMSSubCategory` in `properties` plist:
   - SMSSubCategory=2 → Finance
   - SMSSubCategory=3 → Orders  
   - SMSSubCategory=4 → Reminders
3. **Consider merging**: Same sender with different suffixes should be treated as one chat, using the most specific subcategory

### CORRECTED: is_filtered Bitmask (Verified 2026-01-26)

The suffix was misleading - the `is_filtered` bitmask is the authoritative source:

| Bit | Value | Category |
|-----|-------|----------|
| 0 | 1 | Unknown Sender |
| 1 | 2 | Promotion flag (with bit 0 → is_filtered=3) |
| 2 | 4 | Filtered/Transactional base flag |
| 4 | 16 | **Orders** |
| 5 | 32 | **Finance** (only when bits 4,6 not set) |
| 6 | 64 | **Reminders** |

### Correct Bucket Classification Logic

```
if is_filtered == 3:
    bucket = Promotions
elif is_filtered & 64:  # bit 6
    bucket = Transactions/Reminders
elif is_filtered & 16:  # bit 4
    bucket = Transactions/Orders
elif is_filtered & 32:  # bit 5 (and not bit 4 or 6)
    bucket = Transactions/Finance
elif is_filtered & 4:   # bit 2 only
    bucket = Transactions (generic)
elif is_filtered & 1:   # bit 0
    bucket = Unknown Senders
else:
    bucket = Primary
```

### Verified Counts (matches Messages.app exactly)

| Bucket | is_filtered condition | Count |
|--------|----------------------|-------|
| Promotions | == 3 | 8 ✓ |
| Orders | & 16 | 5 ✓ |
| Reminders | & 64 | 2 ✓ |
| Finance | & 32 (not 16 or 64) | 3 ✓ |
