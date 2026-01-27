---
id: index
title: imessage-ax-research
created: 2026-01-24
modified: 2026-01-26
summary: Research into macOS Accessibility APIs, iMessage chat.db structure, and Beeper desktop integration
---

# imessage-ax-research

## Overview

This knowledge base documents research into the iMessage platform integration for Beeper, covering:
- macOS Accessibility APIs for controlling Messages.app
- chat.db SQLite database structure
- Beeper desktop architecture and filtering

## Contents

### Accessibility Research
- {@ax-chatdb-mapping} - Mapping AX elements to chat.db messages
- {@hiservices-private-apis} - Private HIServices APIs for efficient querying
- {@betterswiftax-analysis} - Analysis of BetterSwiftAX library

### chat.db & Filtering
- {@chatdb-message-filtering} - Message categorization in chat.db (transactions, promotions, spam) **[IMPLEMENTED]**

### Beeper Desktop
- {@beeper-desktop-architecture} - How desktop communicates with bridges and implements filtering

## Data References

- {@chatdb-filter-constants} - Bitmask values for is_filtered column
- {@chatdb-filtering-refs} - Apple documentation links
- {@hiservices-api-addresses} - Function addresses in HIServices binary
- {@hopper-hiservices} - HIServices.framework disassembly
- {@hopper-chatkit} - ChatKit.framework disassembly

## Recent Activity

- 2026-01-26: Implemented chat filtering (transactions, promotions, spam, unknown senders)
- 2026-01-25: Added chat.db filtering research
- 2026-01-24: Created knowledge base with AX research
