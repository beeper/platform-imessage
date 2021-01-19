import Foundation

func decodeStreamTyped(_ filePath: URL) {
  let data = try! Data(contentsOf: filePath)
  let nsu = NSUnarchiver(forReadingWith: data)
  let decoded = nsu?.decodeObject()
  guard let str = decoded as? NSAttributedString else {
    return print("decoded object type unknown")
  }
  // print("🛑 ", type(of: decoded!), filePath, decoded!)
  var result: [String: [String: Any]] = [:]
  str.enumerateAttributes(
    in: NSRange(location: 0, length: str.length),
    options: .longestEffectiveRangeNotRequired
  ) { dict, range, _ in
    for (key, value) in dict {
      result[key.rawValue] = [
        "value": value,
        "from": range.lowerBound,
        "to": range.upperBound,
      ]
    }
  }
  let json = try! JSONSerialization.data(withJSONObject: result)
  print(String(data: json, encoding: .utf8)!)
  print()
}

for i in [
  "closed-rings-1.bin", // NSConcreteAttributedString
  "closed-rings-2.bin", // NSConcreteAttributedString
  "completed-workout-1.bin", // NSConcreteAttributedString
  "completed-workout-2.bin", // NSConcreteAttributedString
  "regular-text.bin", // NSConcreteAttributedString
  "user-mention.bin", // NSConcreteMutableAttributedString
] {
  decodeStreamTyped(URL(fileURLWithPath: i))
}
