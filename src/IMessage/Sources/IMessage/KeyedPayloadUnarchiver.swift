import Foundation
import PlatformSDK

func unarchiveKeyedPayload(_ plist: Any) -> Any? {
    guard let archive = plist as? JSONObject,
          archive["$archiver"] as? String == "NSKeyedArchiver",
          let objects = archive["$objects"] as? [Any],
          let root = archive.dictionary("$top")?["root"] else {
        return nil
    }
    return KeyedPayloadUnarchiver(objects: objects).unarchive(root)
}

private struct KeyedPayloadUnarchiver {
    let objects: [Any]

    func unarchive(_ value: Any) -> Any? {
        if let uid = keyedArchiveUID(value) {
            return unarchiveObject(at: uid)
        }

        switch value {
        case let string as String where string == "$null":
            return NSNull()
        case let dictionary as JSONObject:
            return unarchive(dictionary)
        case let array as JSONArray:
            return array.compactMap(unarchive)
        default:
            return value
        }
    }

    private func unarchiveObject(at index: Int) -> Any? {
        guard objects.indices.contains(index) else {
            return nil
        }
        return unarchive(objects[index])
    }

    private func unarchive(_ dictionary: JSONObject) -> JSONObject {
        var result = JSONObject()
        for (key, child) in dictionary {
            if key == "$classes", let classes = child as? [Any] {
                result[key] = classes
                continue
            }
            guard let mapped = unarchive(child) else {
                continue
            }
            result[key] = value(mapped, forArchiveKey: key)
        }
        return result
    }

    private func value(_ mapped: Any, forArchiveKey key: String) -> Any {
        guard key == "NS.objects",
              let dictionary = mapped as? JSONObject else {
            return mapped
        }
        return dictionary
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .map(\.value)
    }
}

private let keyedArchiveUIDRegex = try! NSRegularExpression(pattern: #"\{value = (\d+)\}"#)

func keyedArchiveUID(_ value: Any) -> Int? {
    if let dictionary = value as? JSONObject, dictionary.count == 1 {
        return dictionary.int("CF$UID")
    }
    if value is JSONObject || value is JSONArray || value is NSDictionary || value is NSArray {
        return nil
    }
    let description = String(describing: value)
    guard description.contains("CFKeyedArchiverUID"),
          let match = description.firstMatch(against: keyedArchiveUIDRegex),
          let uid = Int(match[1]) else {
        return nil
    }
    return uid
}

func unwrapDictionary(_ value: Any) -> JSONObject? {
    guard let dictionary = value as? JSONObject else {
        return nil
    }
    guard let keys = dictionary["NS.keys"] as? [Any],
          let objects = dictionary["NS.objects"] as? [Any] else {
        return value as? JSONObject
    }
    var result = JSONObject()
    for (key, object) in zip(keys, objects) {
        guard let key = key as? String else {
            continue
        }
        result[key] = object
    }
    return result
}

func normalizeFoundationObject(_ value: Any) -> Any {
    switch value {
    case let dictionary as JSONObject:
        return dictionary.reduce(into: JSONObject()) { result, element in
            result[element.key] = normalizeFoundationObject(element.value)
        }
    case let dictionary as NSDictionary:
        var result = JSONObject()
        for (rawKey, rawValue) in dictionary {
            guard let key = rawKey as? String else {
                continue
            }
            result[key] = normalizeFoundationObject(rawValue)
        }
        return result
    case let array as JSONArray:
        return array.map(normalizeFoundationObject)
    case let array as NSArray:
        return array.map(normalizeFoundationObject)
    case let url as URL:
        return ["NS.relative": url.absoluteString]
    case let url as NSURL:
        return ["NS.relative": url.absoluteString ?? ""]
    case let data as Data:
        return "data:;base64,\(data.base64EncodedString())"
    case let data as NSData:
        return "data:;base64,\(data.base64EncodedString())"
    default:
        return value
    }
}
