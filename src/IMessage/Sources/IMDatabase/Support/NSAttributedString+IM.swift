import Foundation

public extension NSAttributedString.Key {
    static var imPart: Self {
        NSAttributedString.Key("__kIMMessagePartAttributeName")
    }

    static var imBaseWritingDirection: Self {
        NSAttributedString.Key("__kIMBaseWritingDirectionAttributeName")
    }

    static var imFileTransferGUID: Self {
        NSAttributedString.Key("__kIMFileTransferGUIDAttributeName")
    }

    static var imBold: Self {
        NSAttributedString.Key("__kIMTextBoldAttributeName")
    }

    static var imItalic: Self {
        NSAttributedString.Key("__kIMTextItalicAttributeName")
    }

    static var imUnderline: Self {
        NSAttributedString.Key("__kIMTextUnderlineAttributeName")
    }

    static var imStrikethrough: Self {
        NSAttributedString.Key("__kIMTextStrikethroughAttributeName")
    }

    static var imLink: Self {
        NSAttributedString.Key("__kIMLinkAttributeName")
    }

    static var imConfirmedMention: Self {
        NSAttributedString.Key("__kIMMentionConfirmedMention")
    }

    static var imOneTimeCode: Self {
        NSAttributedString.Key("__kIMOneTimeCodeAttributeName")
    }

    static var imPluginPayload: Self {
        NSAttributedString.Key("__kIMPluginPayloadAttributeName")
    }

    static var imBreadcrumbTextMarker: Self {
        NSAttributedString.Key("__kIMBreadcrumbTextMarkerAttributeName")
    }
}
