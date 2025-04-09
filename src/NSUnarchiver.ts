import { mapValues } from 'lodash'
import { UID, Plist } from './bplist-parser'

function mapObject(root: Plist, definedObjects?: Plist[]): Plist | null {
  if (root === '$null') return null

  if (typeof root === 'object') {
    if (root instanceof UID && root.uid != null && definedObjects != null) {
      return mapObject(definedObjects?.[root.uid], definedObjects)
    }

    return mapValues(root, (value, key) => {
      if (key === '$classes') return Object.values(value)
      if (key === 'NS.objects') {
        const mapped = mapObject(value, definedObjects)
        if (!mapped) throw new Error("imsg unarchive: couldn't map NS.objects")
        return Object.values(mapped)
      }

      return mapObject(value, definedObjects)
    })
  }

  return root
}

export function unwrapDictionary(payloadData: any) {
  const { 'NS.keys': keys, 'NS.objects': objects } = payloadData
  const result: any = {}
  Object.entries<string>(keys).forEach(([indexStr, keyName]) => {
    result[keyName] = objects[+indexStr]
  })
  return result
}

export default function unarchive(plist: Plist) {
  if (!plist) {
    throw new TypeError('plist to unarchive is empty')
  }
  if (typeof plist !== 'object') {
    throw new TypeError("plist to unarchive isn't a dictionary")
  }
  if (!('$version' in plist && '$archiver' in plist && '$objects' in plist && '$top' in plist)) {
    throw new TypeError("plist to unarchive doesn't have expected properties")
  }

  if (plist.$version !== 100000 || plist.$archiver !== 'NSKeyedArchiver' || !plist.$objects) {
    console.error('imsg unarchive: unknown format', plist)
    return plist
  }

  if (!(typeof plist.$top === 'object' && plist.$top && 'root' in plist.$top)) {
    console.error('imsg unarchive: no root', plist)
    return plist
  }

  return mapObject(plist.$top.root, Array.isArray(plist.$objects) ? plist.$objects : [])
}
