export { shellExec } from './shell-exec'

const getDataURI = (buffer: Buffer, mimeType = '') =>
  `data:${mimeType};base64,${buffer.toString('base64')}`

export const stringifyWithArrayBuffers = <T>(obj: T, space?: string | number) =>
  JSON.stringify(
    obj,
    function (key: string, value: any) {
      if (value === null || typeof value !== 'object') return value
      const originalValue = this[key]
      if (ArrayBuffer.isView(originalValue)) {
        return getDataURI(Buffer.from(
          originalValue.buffer,
          originalValue.byteOffset,
          originalValue.byteLength,
        ))
      }
      return value
    },
    space,
  )
