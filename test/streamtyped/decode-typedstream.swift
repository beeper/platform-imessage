import Foundation

func streamTypedNSAttributedStringToJSON(_ data: Data) -> String {
  let nsu = NSUnarchiver(forReadingWith: data)
  let decoded = nsu?.decodeObject()
  guard let str = decoded as? NSAttributedString else {
    return "undefined" // "decoded object type unknown"
  }
  var result: [[String: Any]] = []
  str.enumerateAttributes(
    in: NSRange(location: 0, length: str.length),
    options: .longestEffectiveRangeNotRequired
  ) { dict, range, _ in
    for (key, val) in dict {
      let type = type(of: val)
      let stringType = "\(type)"
      let value: String? = String(describing: val)
      result.append([
        "key": key.rawValue,
        "type": stringType,
        "value": value as Any,
        "from": range.lowerBound,
        "to": range.upperBound,
      ])
    }
  }
  let json = try! JSONSerialization.data(withJSONObject: result)
  return String(data: json, encoding: .utf8)!
}

guard CommandLine.arguments.count > 1 else {
  fputs("usage: decode-typedstream.swift <file>\n", stderr)
  exit(1)
}

let filePath = CommandLine.arguments[1]
let data = try! Data(contentsOf: URL(fileURLWithPath: filePath))
let jsonString = streamTypedNSAttributedStringToJSON(data)
print(jsonString)
