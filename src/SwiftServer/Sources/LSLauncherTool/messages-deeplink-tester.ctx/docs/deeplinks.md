---
id: deeplinks
title: Deep Link Format
created: 2026-01-27
summary: iMessage deep link URL format and test cases from Kishan conversation
modified: 2026-01-27
---

# Deep Link Format

TODO: Add content

## URL Format

```
imessage://open?message-guid=<GUID>
```

The GUID is from the `message.guid` column in chat.db. Must NOT contain underscores.

## Other Deep Link Types

```swift
// Single address
imessage://open?address=+15551234567

// Multiple addresses  
imessage://open?addresses=addr1,addr2

// Group chat
imessage://open?groupid=<chat_id>

// With body text
imessage://open?address=...&body=Hello
```

## Test Cases from Kishan

Source: `~/Library/Messages/chat.db` - handle `hi@kishan.info`

See {@test-guids} for the full list.

## Querying chat.db

```sql
SELECT m.guid, m.text, 
       datetime((m.date/1000000000) + 978307200, 'unixepoch', 'localtime') as date_str
FROM message m 
JOIN chat_message_join cmj ON m.ROWID = cmj.message_id 
JOIN chat c ON cmj.chat_id = c.ROWID 
WHERE c.chat_identifier LIKE '%kishan%' 
ORDER BY m.date DESC LIMIT 10;
```
