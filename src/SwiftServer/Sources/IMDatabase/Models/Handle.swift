public struct Handle {
    public var rowid: Int

    // - phone number (formatted like "+17075551234")
    //   - can be shortcode (like "30300")
    // - email
    // - "urn:biz:<uuid>"
    public var id: String
}
