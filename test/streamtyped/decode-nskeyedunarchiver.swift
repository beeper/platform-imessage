import Foundation

func unarchive(_ data: Data) throws {
  let nku = try NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)
  print(nku, type(of: nku))
  let cmat = nku! as! NSMutableAttributedString
  let attributes = cmat.attributes(at: 0, effectiveRange: nil)
  for attr in attributes {
    print(attr.key, attr.value, type(of: attr.value))
  }
}

for filePath in [
  "composition-text.bin",
  "composition-shelfPluginPayload.bin",
] {
  print(filePath)
  let data = try! Data(contentsOf: URL(fileURLWithPath: filePath))
  print(Result { try unarchive(data) })
  print(NSDictionary(contentsOfFile: filePath))
}
