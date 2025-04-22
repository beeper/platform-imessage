import Cool
import Foundation

struct RageshakeFile {
    var parent: Rageshake
    var fileName: String
}

extension RageshakeFile {
    init(within parent: Rageshake, fileName: String) {
        self.parent = parent
        self.fileName = fileName
    }
}

extension RageshakeFile {
    func url(authenticatingWith method: Rageshake.AuthenticationMethod) -> URL {
        parent.url(authenticatingWith: method) / fileName
    }
}

extension RageshakeFile: Identifiable {
    var id: String {
        "\(parent.date)/\(parent.id)"
    }
}

extension RageshakeFile: Equatable {
    static func == (lhs: RageshakeFile, rhs: RageshakeFile) -> Bool {
        lhs.id == rhs.id
    }
}
