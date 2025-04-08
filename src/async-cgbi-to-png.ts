// adapted from https://github.com/an3park/async-cgbi-to-png/blob/master/src/index.ts

import zlib from 'zlib'
import { crc32 } from 'crc'
import { promisify } from 'util'

const asyncInflateRaw = promisify<zlib.InputType, Buffer>(zlib.inflateRaw)
const asyncDeflate = promisify<zlib.InputType, Buffer>(zlib.deflate)
const PNG_HEADER = Buffer.from('89504e470d0a1a0a', 'hex')

function createUInt32BE(value: number) {
  const buf = Buffer.alloc(4)
  buf.writeUInt32BE(value)
  return buf
}

class Reader {
  offset = 0

  constructor(readonly buf: Buffer) {}

  read(bytes: number): Buffer {
    this.offset += bytes
    return this.buf.slice(this.offset - bytes, this.offset)
  }
}

interface PngHeaderData {
  width: number
  height: number
  bitDeph: number
  colorType: number
  comressMethod: number
  filterMethod: number
  interlaceMethod: number
}

async function defaultTransform(
  image: Buffer,
  width: number,
  height: number,
): Promise<Buffer> {
  const uncompressed = await asyncInflateRaw(image)
  const newData = Buffer.alloc(uncompressed.length)
  let i = 0
  for (let j = 0; j < height; ++j) {
    newData[i] = uncompressed[i]
    i++
    for (let k = 0; k < width; ++k) {
      newData[i + 0] = uncompressed[i + 2]
      newData[i + 1] = uncompressed[i + 1]
      newData[i + 2] = uncompressed[i + 0]
      newData[i + 3] = uncompressed[i + 3]
      i += 4
    }
  }
  return asyncDeflate(newData)
}

export async function convertCGBI(cgbi: Buffer) {
  if (cgbi.slice(0, 8).compare(PNG_HEADER)) {
    throw new Error('not png')
  }

  const reader = new Reader(cgbi)
  reader.offset = 8
  const result = [PNG_HEADER]
  let isCgBI = false
  let header: PngHeaderData | undefined
  const idat = [] as Buffer[]

  while (reader.offset < cgbi.length) {
    const len = reader.read(4).readUInt32BE()
    const type = reader.read(4).toString()
    const data = reader.read(len)
    const chsum = reader.read(4)

    switch (type) {
      case 'CgBI':
        isCgBI = true
        break

      case 'iDOT':
        break

      case 'IDAT':
        idat.push(data)
        break

      case 'IEND': {
        const rawdata = Buffer.concat(idat)
        if (!header) {
          throw new Error('error while reading png header')
        }
        const newIdat = await defaultTransform(rawdata, header.width, header.height)
        let idatCRC = crc32('IDAT')
        idatCRC = crc32(newIdat, idatCRC)
        idatCRC = (idatCRC + 0x100000000) % 0x100000000
        result.push(
          createUInt32BE(newIdat.length),
          Buffer.from('IDAT'),
          newIdat,
          createUInt32BE(idatCRC),
          Buffer.alloc(4),
          Buffer.from('IEND'),
          chsum,
        )

        return Buffer.concat(result)
      }

      case 'IHDR':
        if (!isCgBI) return cgbi
        header = {
          width: data.readUInt32BE(),
          height: data.readUInt32BE(4),
          bitDeph: data.readUInt8(8),
          colorType: data.readUInt8(9),
          comressMethod: data.readUInt8(10),
          filterMethod: data.readUInt8(11),
          interlaceMethod: data.readUInt8(12),
        }

      // eslint-disable-next-line no-fallthrough
      default:
        result.push(createUInt32BE(len), Buffer.from(type), data, chsum)
        break
    }
  }

  throw new Error('didn\'t reach IEND chunk')
}
