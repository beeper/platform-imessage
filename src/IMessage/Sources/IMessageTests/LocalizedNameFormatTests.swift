import Foundation
@testable import IMessage
import Testing

// Deduplicated values of UNAVAILABILITY_INDICATOR_TITLE_FORMAT and
// contact.typing.message.with.name from all 37 loctables snapshots (13.0.1–27.2.1).
@Test
func localizedNameFormatsFromLoctables() throws {
    let url = try #require(Bundle.module.url(forResource: "localized_name_formats", withExtension: "json"))
    let formats = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: url))
    for (kind, values) in formats {
        for format in values {
            let matcher = try #require(LocalizedNameFormat(format))
            for name in ["Steve", "สมชาย", "ليلى", "אור", "A 👩🏽‍💻\nB"] {
                let label = format.replacingOccurrences(of: "%[tt]@", with: name)
                    .replacingOccurrences(of: "%@", with: name)
                #expect(matcher.matches(label), "\(format)")
                if kind == "focus" {
                    #expect(matcher.matches("\u{FFFC} " + label, allowingAttachmentPrefix: true))
                    #expect(matcher.matches("\u{FFFC}" + label, allowingAttachmentPrefix: true))
                }
                if !format.hasSuffix("%@"), !format.hasSuffix("%[tt]@") {
                    #expect(!matcher.matches(label + " unrelated"))
                }
            }
            let withoutName = format.replacingOccurrences(of: "%[tt]@", with: "")
                .replacingOccurrences(of: "%@", with: "")
            #expect(!matcher.matches(withoutName))
            #expect(!matcher.matches("unrelated message"))
        }
    }
}

@Test
func localizedNameFormatRequiresBothLiteralParts() throws {
    let matcher = try #require(LocalizedNameFormat("Voor %@ worden meldingen stilgehouden"))
    #expect(!matcher.matches("Steve worden meldingen stilgehouden"))
    #expect(!matcher.matches("Voor Steve"))
    #expect(!matcher.matches("Unrelated Voor Steve worden meldingen stilgehouden"))
    #expect(!matcher.matches("\u{FFFC} Voor Steve worden meldingen stilgehouden"))
    let punctuation = try #require(LocalizedNameFormat("[Contact] %@ (typing)."))
    #expect(punctuation.matches("[Contact] Steve (typing)."))
    #expect(!punctuation.matches("Contact Steve typing"))
}

@Test
func localizedNameFormatRejectsMissingOrAmbiguousPlaceholders() {
    for format in ["", "contact.typing.message.with.name", "%@", "%[tt]@", "%@ and %@ typing", "%d typing"] {
        #expect(LocalizedNameFormat(format) == nil)
    }
}
