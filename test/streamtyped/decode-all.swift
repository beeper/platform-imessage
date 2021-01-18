import Foundation

func decodeStreamTyped(_ filePath: URL) {
  let data = try! Data(contentsOf: filePath)
  let nsu = NSUnarchiver(forReadingWith: data)
  let decoded = nsu?.decodeObject()
  print("🛑 ------", type(of: decoded!), filePath, "------")
  print(decoded!)
}

decodeStreamTyped(URL(fileURLWithPath: "closed-rings-1.bin"))
decodeStreamTyped(URL(fileURLWithPath: "closed-rings-2.bin"))
decodeStreamTyped(URL(fileURLWithPath: "completed-workout-1.bin"))
decodeStreamTyped(URL(fileURLWithPath: "completed-workout-2.bin"))
decodeStreamTyped(URL(fileURLWithPath: "user-mention.bin"))
