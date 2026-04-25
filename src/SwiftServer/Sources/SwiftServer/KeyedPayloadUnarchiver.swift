import Foundation

func unarchiveKeyedPayload(_ plist: Any) -> Any? {
    guard let archive = plist as? JSONObject,
          archive["$archiver"] as? String == "NSKeyedArchiver",
          let objects = archive["$objects"] as? [Any],
          let root = archive.dictionary("$top")?["root"] else {
        return nil
    }
    return mapArchivedObject(root, objects: objects)
}

func mapArchivedObject(_ value: Any, objects: [Any]) -> Any? {
    if let uid = keyedArchiveUID(value) {
        guard objects.indices.contains(uid) else {
            return nil
        }
        return mapArchivedObject(objects[uid], objects: objects)
    }
    if let string = value as? String, string == "$null" {
        return NSNull()
    }
    if let dictionary = value as? JSONObject {
        var result = JSONObject()
        for (key, child) in dictionary {
            if key == "$classes", let classes = child as? [Any] {
                result[key] = classes
                continue
            }
            guard let mapped = mapArchivedObject(child, objects: objects) else {
                continue
            }
            if key == "NS.objects", let mappedDictionary = mapped as? JSONObject {
                result[key] = mappedDictionary
                    .sorted { lhs, rhs in (Int(lhs.key) ?? 0) < (Int(rhs.key) ?? 0) }
                    .map(\.value)
            } else {
                result[key] = mapped
            }
        }
        return result
    }
    if let array = value as? [Any] {
        return array.compactMap { mapArchivedObject($0, objects: objects) }
    }
    return value
}

func keyedArchiveUID(_ value: Any) -> Int? {
    if let dictionary = value as? JSONObject,
       dictionary.count == 1,
       let uid = dictionary["CF$UID"] {
        return (uid as? NSNumber)?.intValue ?? uid as? Int
    }
    if value is JSONObject || value is JSONArray || value is NSDictionary || value is NSArray {
        return nil
    }
    let description = String(describing: value)
    guard description.contains("CFKeyedArchiverUID"),
          let match = description.firstMatch(of: #"\{value = (\d+)\}"#),
          let uid = Int(match[1]) else {
        return nil
    }
    return uid
}

func unwrapDictionary(_ value: Any) -> JSONObject? {
    guard let dictionary = value as? JSONObject,
          let keys = dictionary["NS.keys"] as? [Any],
          let objects = dictionary["NS.objects"] as? [Any] else {
        return value as? JSONObject
    }
    var result = JSONObject()
    for (index, key) in keys.enumerated() {
        guard let key = key as? String, objects.indices.contains(index) else {
            continue
        }
        result[key] = objects[index]
    }
    return result
}

func normalizeFoundationObject(_ value: Any) -> Any {
    switch value {
    case let dictionary as NSDictionary:
        var result = JSONObject()
        for (rawKey, rawValue) in dictionary {
            guard let key = rawKey as? String else {
                continue
            }
            result[key] = normalizeFoundationObject(rawValue)
        }
        return result
    case let array as NSArray:
        return array.map(normalizeFoundationObject)
    case let url as NSURL:
        return ["NS.relative": url.absoluteString ?? ""]
    case let data as NSData:
        return "data:;base64,\(data.base64EncodedString())"
    default:
        return value
    }
}
