import { mapValues } from 'lodash'

function mapObject(o: any, objects: any[]) {
  if (o === '$null') return null
  if (typeof o === 'object') {
    if (o.UID != null) return mapObject(objects[o.UID], objects)
    return mapValues(o, (v: any, k: string) => {
      if (k === '$classes') return Object.values(v)
      if (k === 'NS.objects') return Object.values(mapObject(v, objects))
      return mapObject(v, objects)
    })
  }
  return o
}

export default function unarchive(plist: any) {
  if (!plist) throw TypeError('`plist` is empty')
  if (plist.$version !== 100000 || plist.$archiver !== 'NSKeyedArchiver' || !plist.$objects) {
    console.log('warning: unknown format', plist)
    return plist
  }
  return mapObject(plist.$top.root, plist.$objects)
}
