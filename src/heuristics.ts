const entirelyNumbersAndSymbols = /^[\d\s+\-()]+$/
// https://web.archive.org/web/20250624231541/https://api.support.vonage.com/hc/en-us/articles/204017783-United-Kingdom-SMS-Features-and-Restrictions
const entirelyAlphanumericSenderID = /^[\da-zA-Z .&_/-]{1,11}$/

// https://en.wikipedia.org/wiki/Mobile_marketing#Custom_Sender_ID
export function likelyAlphanumericSenderID(id: string): boolean {
  return !entirelyNumbersAndSymbols.test(id) && entirelyAlphanumericSenderID.test(id)
}
