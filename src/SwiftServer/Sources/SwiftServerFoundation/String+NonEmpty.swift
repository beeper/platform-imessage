
public extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
