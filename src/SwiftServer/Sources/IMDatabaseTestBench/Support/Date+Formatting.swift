import Foundation

extension Date? {
    var formatted: String {
        guard let self else {
            return "(no date)"
        }

        if #available(macOS 12, *) {
            let relative = self.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            let absolute = self.formatted()
            return "\(absolute) (\(relative))"
        } else {
            return "\(self)"
        }
    }
}
