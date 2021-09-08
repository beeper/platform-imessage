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


for filePath in [
  "closed-rings-1.bin", // NSConcreteAttributedString
  "closed-rings-2.bin", // NSConcreteAttributedString
  "completed-workout-1.bin", // NSConcreteAttributedString
  "completed-workout-2.bin", // NSConcreteAttributedString
  "regular-text.bin", // NSConcreteAttributedString
  "user-mention.bin", // NSConcreteMutableAttributedString
  "tweet.bin",
] {
  let data = try! Data(contentsOf: URL(fileURLWithPath: filePath))
  let jsonString = streamTypedNSAttributedStringToJSON(data)
  print(jsonString)
  print()
}
