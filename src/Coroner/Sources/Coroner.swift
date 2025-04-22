import ArgumentParser
import Foundation

@main
struct Coroner: AsyncParsableCommand {
    @Option(name: [.customShort("p"), .customLong("password")], help: "The password to use when authenticating with rageshake.beeper.com.")
    var rageshakePassword: String

    @Argument(help: "The URL of the Rageshake listing to examine.")
    var rageshakeURL: URL

    mutating func run() async throws {
        let rs = try Rageshake(at: rageshakeURL).orThrow("couldn't construct rageshake")
        try await print(rs.files(authenticatingWithPassword: rageshakePassword))
    }
}

extension URL: @retroactive ExpressibleByArgument {
    public init?(argument: String) {
        self.init(string: argument)
    }
}
