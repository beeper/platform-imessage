// milliseconds since 2001-01-01 00:00:00 GMT, relative to the unix epoch
// `AppleDate` is expressed as a quantity of _nanoseconds_ relative to this
// reference date. this format is used by apple's Core Foundation, Core Data,
// etc.
//
// https://developer.apple.com/documentation/corefoundation/cfabsolutetime
export const CORE_FOUNDATION_REFERENCE_DATE_MS = 978307200000

// use a branded type to prevent confusion
const AppleDateBrand: unique symbol = Symbol.for('AppleDate')
/** A timestamp represented as a quantity of nanoseconds since 2001-01-01 00:00:00 GMT. */
export type AppleDate = string & {
  readonly [AppleDateBrand]: unknown
}

/** Returns an {@linkcode AppleDate} as a stringified number of nanoseconds since {@linkcode CORE_FOUNDATION_REFERENCE_DATE_MS}. */
export function unwrapAppleDate(appleDate: AppleDate): string | undefined {
  const string = appleDate as string
  // Apple frequently uses a date value of 0 to represent no value.
  if (string === '0') {
    return undefined
  }
  return string
}

export function millisToNanos(millis: bigint): bigint
export function millisToNanos(millis: number): number
export function millisToNanos(millis: bigint | number): bigint | number {
  if (typeof millis === 'bigint') {
    return millis * 1_000_000n
  }
  return millis * 1_000_000
}

export function nanosToMs(nanos: bigint): bigint
export function nanosToMs(nanos: number): number
export function nanosToMs(nanos: bigint | number): bigint | number {
  if (typeof nanos === 'bigint') {
    return nanos / 1_000_000n
  }
  return nanos / 1_000_000
}

export function makeAppleDate(date: Date): AppleDate {
  return String(millisToNanos(BigInt(date.getTime() - CORE_FOUNDATION_REFERENCE_DATE_MS))) as AppleDate
}

export function appleDateToMillisSinceEpoch(appleDate: AppleDate): number | undefined {
  const nanosSinceReferenceString = unwrapAppleDate(appleDate)
  if (!nanosSinceReferenceString) return undefined

  const millisSinceReference = nanosToMs(BigInt(nanosSinceReferenceString))
  if (millisSinceReference > Number.MAX_SAFE_INTEGER) {
    throw new Error(`imsg: don't have enough precision to represent an apple timestamp even after converting to milliseconds (${millisSinceReference}ms)`)
  }

  const millisSinceUnixEpoch = Number(millisSinceReference) + CORE_FOUNDATION_REFERENCE_DATE_MS
  return Math.round(millisSinceUnixEpoch)
}

export function appleDateNow(): AppleDate {
  return makeAppleDate(new Date())
}

/** Converts a {@linkcode AppleDate} to a normal {@linkcode Date}. */
export function regularlizeAppleDate(appleDate: AppleDate): Date | undefined {
  const millis = appleDateToMillisSinceEpoch(appleDate)
  if (!millis) return undefined
  return new Date(millis)
}
