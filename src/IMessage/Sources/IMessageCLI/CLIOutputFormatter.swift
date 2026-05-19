import ArgumentParser
import Foundation
import IMessage
import Yams
#if IMESSAGE_CLI_ENABLE_CHROMA
import Chroma
#endif

enum OutputFormat: String, ExpressibleByArgument {
    case json
    case yaml

    init?(argument: String) {
        switch argument.lowercased() {
        case "json":
            self = .json
        case "yaml", "yml":
            self = .yaml
        default:
            return nil
        }
    }
}

struct CLIOutputFormatter {
    var outputFormat: OutputFormat

    func printJSON(_ raw: String) {
        print(formatJSON(raw))
    }

    func printValue(_ value: Any) {
        guard let json = try? encodeJSON(value) else {
            print(String(describing: value))
            return
        }
        printJSON(json)
    }

    func formatJSON(_ raw: String) -> String {
        Self.formatJSON(raw, outputFormat: outputFormat)
    }

    static func formatJSON(_ raw: String, outputFormat: OutputFormat) -> String {
        let formatted: String
        switch outputFormat {
        case .json:
            formatted = prettyJSONString(raw)
        case .yaml:
            guard let value = parseJSONValue(raw),
                  let yaml = try? Yams.dump(object: yamlSerializable(value)) else {
                return raw
            }
            formatted = yaml.trimmingCharacters(in: .newlines)
        }
        return syntaxHighlighted(formatted, outputFormat: outputFormat)
    }

    static func prettyJSONString(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let pretty = String(data: prettyData, encoding: .utf8)
        else {
            return raw
        }
        return pretty
    }

    private static func parseJSONValue(_ raw: String) -> Any? {
        guard let data = raw.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private static func syntaxHighlighted(_ value: String, outputFormat: OutputFormat) -> String {
        #if IMESSAGE_CLI_ENABLE_CHROMA
        if #available(macOS 13, *) {
            let language: LanguageID = outputFormat == .json ? .json : .yaml
            let options = HighlightOptions(
                colorMode: .auto(output: .stdout),
                missingLanguageHandling: .fallbackToPlainText,
                diff: .none
            )
            return (try? Chroma.highlight(value, language: language, options: options)) ?? value
        }
        #endif
        return value
    }

    private static func yamlSerializable(_ value: Any) -> Any {
        switch value {
        case _ as NSNull:
            return NSNull()
        case let dictionary as [String: Any]:
            return dictionary.mapValues(yamlSerializable)
        case let dictionary as NSDictionary:
            var result = [String: Any]()
            for (key, value) in dictionary {
                guard let key = key as? String else { continue }
                result[key] = yamlSerializable(value)
            }
            return result
        case let array as [Any]:
            return array.map(yamlSerializable)
        case let array as NSArray:
            return array.map(yamlSerializable)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            switch CFNumberGetType(number) {
            case .floatType, .float32Type, .float64Type, .doubleType, .cgFloatType:
                return number.doubleValue
            default:
                return number.int64Value
            }
        default:
            return value
        }
    }
}

func formatValue(_ value: Any) -> String {
    guard let string = try? encodeJSON(value) else { return String(describing: value) }
    return CLIOutputFormatter.prettyJSONString(string).replacingOccurrences(of: "\n", with: " ")
}
