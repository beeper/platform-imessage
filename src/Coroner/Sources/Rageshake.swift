import Cool
import Foundation
import RegexBuilder

struct Rageshake: Identifiable {
    var date: String
    var id: String
}

extension Rageshake: Equatable {
    static func == (lhs: Rageshake, rhs: Rageshake) -> Bool {
        lhs.id == rhs.id && lhs.date == rhs.date
    }
}

extension Rageshake {
    private static func extract(from url: URL) -> (date: Substring, id: Substring)? {
        let date = Reference<Substring>()
        let id = Reference<Substring>()

        // matches e.g. https://rageshake-sso.beeper.com/api/listing/2025-04-17/154418-D6MGM3PF/
        let rageshakeURLRegex = Regex {
            /https?:/
            "//"
            ChoiceOf { "rageshake-sso"; "rageshake" }
            ".beeper.com/api/listing/"
            Capture(as: date) { /[\d-]+/ }
            "/"
            Capture(as: id) { /[\da-zA-Z-]+/ }
            Optionally { "/" }
        }

        guard let match = url.absoluteString.wholeMatch(of: rageshakeURLRegex) else {
            return nil
        }

        return (date: match[date], id: match[id])
    }

    init?(at url: URL) {
        guard let (date, id) = Self.extract(from: url) else {
            return nil
        }

        self.date = String(date)
        self.id = String(id)
    }
}

extension Rageshake {
    enum AuthenticationMethod {
        case basic
        case singleSignOn

        var subdomain: String {
            switch self {
            case .basic: "rageshake"
            case .singleSignOn: "rageshake-sso"
            }
        }
    }

    func url(authenticatingWith variant: AuthenticationMethod) -> URL {
        URL(string: "https://\(variant.subdomain).beeper.com/api/listing/\(date)/\(id)/")!
    }
}

extension Rageshake {
    enum Error: Swift.Error {
        case http(HTTPURLResponse)
        case decoding
    }
}

extension Rageshake {
    func files(authenticatingWithPassword password: String) async throws -> [RageshakeFile] {
        var request = URLRequest(url: url(authenticatingWith: .basic))
        request.addAuthorization(username: "rageshake", password: password)
        let (listing, response_) = try await URLSession.rageshake.data(for: request)
        let response = try (response_ as? HTTPURLResponse).orThrow("expected http response")
        guard (200 ..< 300).contains(response.statusCode) else {
            throw Error.http(response)
        }
        return try extractFiles(fromListing: listing)
    }

    private func extractFiles(fromListing html: Data) throws -> [RageshakeFile] {
        let html = try String(data: html, encoding: .utf8).orThrow(Error.decoding)
        return html.matches(of: {
            let quote = "\""
            "<a href="
            quote
            Capture { /[\w.-]+/ }
            quote
        }).map(\.output.1).map { RageshakeFile(within: self, fileName: String($0)) }
    }
}

private extension URLRequest {
    mutating func addAuthorization(username: String, password: String) {
        let encoded = Data("\(username):\(password)".utf8).base64EncodedString()
        addValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
}

private extension URLSession {
    static let rageshake: URLSession = .init(configuration: with(URLSessionConfiguration.default) {
        $0.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        $0.httpAdditionalHeaders = ["User-Agent": "Coroner/0.0"]
        $0.httpShouldSetCookies = true
        $0.httpCookieStorage = HTTPCookieStorage()
    })
}
