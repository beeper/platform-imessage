const entirelyNumbersAndSymbols = /^[\d\s+\-()]+$/
// https://web.archive.org/web/20250624231541/https://api.support.vonage.com/hc/en-us/articles/204017783-United-Kingdom-SMS-Features-and-Restrictions
const entirelyAlphanumericSenderID = /^[\da-zA-Z .&_/-]{1,11}$/

// NOTE: imessage can canonicalize SMS shortcodes; only pass uncanonicalized IDs
// if possible: https://www.notion.so/beeper/Canonicalization-Notes-255a168aa37080c189c0d616724830e4?source=copy_link
// see: https://en.wikipedia.org/wiki/Mobile_marketing#Custom_Sender_ID
export function likelyAlphanumericSenderID(uncanonicalizedID: string): boolean {
  return !entirelyNumbersAndSymbols.test(uncanonicalizedID) && entirelyAlphanumericSenderID.test(uncanonicalizedID)
}
