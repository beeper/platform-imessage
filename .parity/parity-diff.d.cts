export type ParityDiff = {
  path: string
  kind: 'missing-in-swift' | 'missing-in-reference' | 'type' | 'value' | 'length'
}

export function normalizeParityValue(value: unknown, key?: string): unknown
export function normalizeForParityDelta(phase: string, value: unknown): unknown
export function diffParityValues(swiftValue: unknown, referenceValue: unknown, pathName?: string, diffs?: ParityDiff[]): ParityDiff[]
