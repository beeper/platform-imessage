import Foundation

public extension NSAttributedString.Key {
    static let imPart = Self("__kIMMessagePartAttributeName")

    static let imBaseWritingDirection = Self("__kIMBaseWritingDirectionAttributeName")

    static let imFileTransferGUID = Self("__kIMFileTransferGUIDAttributeName")

    static let imBold = Self("__kIMTextBoldAttributeName")

    static let imItalic = Self("__kIMTextItalicAttributeName")

    static let imUnderline = Self("__kIMTextUnderlineAttributeName")

    static let imStrikethrough = Self("__kIMTextStrikethroughAttributeName")

    static let imLink = Self("__kIMLinkAttributeName")

    static let imConfirmedMention = Self("__kIMMentionConfirmedMention")

    static let imOneTimeCode = Self("__kIMOneTimeCodeAttributeName")

    static let imPluginPayload = Self("__kIMPluginPayloadAttributeName")

    static let imBreadcrumbTextMarker = Self("__kIMBreadcrumbTextMarkerAttributeName")
}
