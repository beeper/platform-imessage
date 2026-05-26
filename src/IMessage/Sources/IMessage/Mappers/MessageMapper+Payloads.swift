import Foundation
import IMessageCore
import PlatformSDK

extension Mapper {
    func payloadData() -> Any? {
        guard let data = messageRow.payloadData else {
            return nil
        }
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
            let normalized = normalizeFoundationObject(plist)
            return unarchiveKeyedPayload(normalized) ?? normalized
        }
        if let object = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) {
            return normalizeFoundationObject(object)
        }
        return nil
    }

    func payloadProps(
        from payloadData: Any,
        messageAttachments: [PlatformSDK.Attachment],
        bundleKind: BalloonBundleKind?
    ) -> MessagePatch {
        guard let bundleKind else {
            return MessagePatch()
        }
        switch bundleKind {
        case .url:
            return urlBalloonProps(from: payloadData, messageAttachments: messageAttachments)
        case .applePay:
            return applePayProps(from: payloadData)
        case .findMy:
            return findMyProps(from: payloadData)
        case .gamePigeon:
            return gamePigeonProps(from: payloadData)
        case .polls:
            return pollProps(from: payloadData)
        case .youtube:
            return youTubeProps(from: payloadData)
        case .digitalTouch, .handwriting, .businessExtension:
            return MessagePatch()
        }
    }

    func urlBalloonProps(from payloadData: Any, messageAttachments: [PlatformSDK.Attachment]) -> MessagePatch {
        guard let payload = payloadData as? JSONObject,
              let richLinkMetadata = payload.dictionary("richLinkMetadata") else {
            return MessagePatch()
        }
        let payloadAttachments = pluginPayloadAttachments(from: messageAttachments)
        let attachments = richLinkAttachments(richLinkMetadata: richLinkMetadata, payloadAttachments: payloadAttachments)
        let parsedURL = relativeURL(richLinkMetadata["URL"])
        let originalURL = relativeURL(richLinkMetadata["originalURL"])
        let linkURL = originalURL ?? parsedURL

        if let tweetProps = tweetProps(
            richLinkMetadata: richLinkMetadata,
            payloadAttachments: payloadAttachments,
            attachments: attachments,
            linkURL: linkURL,
            originalURL: originalURL
        ) {
            return tweetProps
        }

        let iframeURL = relativeURL(richLinkMetadata.dictionary("video")?.dictionary("youTubeURL"))?
            .replacingOccurrences(of: "autoplay=1", with: "")
        let imageIndex = richLinkMetadata.dictionary("image")?.int("richLinkImageAttachmentSubstituteIndex")
        let imageAttachment = iframeURL == nil
            ? imageIndex.flatMap { payloadAttachments[safe: $0] }
            : nil
        guard let linkURL else {
            return MessagePatch()
        }
        var favicon: String?
        if imageAttachment?.srcURL == nil,
           let iconIndex = richLinkMetadata.dictionary("icon")?.int("richLinkImageAttachmentSubstituteIndex"),
           let icon = payloadAttachments[safe: iconIndex] {
            favicon = icon.srcURL
        }
        let title = richLinkMetadata.string("title").flatMap { $0.isEmpty ? nil : $0 }
        let summary = richLinkMetadata.string("summary")
        if imageAttachment?.srcURL == nil, title == nil, summary == nil, favicon == nil {
            return MessagePatch()
        }
        let link = PlatformSDK.MessageLink(
            url: linkURL,
            favicon: favicon,
            img: imageAttachment?.srcURL,
            imgSize: imageAttachment?.size,
            title: title,
            summary: summary
        )
        return MessagePatch(
            attachments: iframeURL == nil ? attachments : [],
            links: [link],
            iframeURL: iframeURL
        )
    }

    func externalVideos(from videos: Any?) -> [PlatformSDK.Attachment] {
        guard let videos = videos as? JSONObject else {
            return []
        }
        return videos.array("NS.objects").compactMap { video -> PlatformSDK.Attachment? in
            guard let video = video as? JSONObject,
                  video.string("type") != "text/html",
                  let srcURL = relativeURL(video["URL"]),
                  let size = parseSize(video.string("size")) else {
                return nil
            }
            return PlatformSDK.Attachment(
                id: srcURL,
                type: .video,
                size: size,
                srcURL: srcURL
            )
        }
    }

    func applePayProps(from payloadData: Any) -> MessagePatch {
        guard let payload = payloadData as? JSONObject,
              let objects = payload["NS.objects"] as? [Any],
              let heading = objects.first as? String,
              !heading.hasPrefix("data:;base64,") else {
            return MessagePatch()
        }
        return MessagePatch(textHeading: heading)
    }

    func youTubeProps(from payloadData: Any) -> MessagePatch {
        guard let unwrapped = unwrapDictionary(payloadData) else {
            return MessagePatch()
        }
        guard let url = relativeURL(unwrapped["URL"]) else {
            return MessagePatch(attachments: [])
        }
        return MessagePatch(
            attachments: [],
            links: [PlatformSDK.MessageLink(
                url: url,
                title: unwrapped["ldtext"].map { "\($0)" }.flatMap { $0.isEmpty ? nil : $0 }
            )]
        )
    }

    func findMyProps(from payloadData: Any) -> MessagePatch {
        guard let payload = unwrapDictionary(payloadData) else {
            return MessagePatch(textHeading: "Find My")
        }
        let heading = pluginPayloadAppName(payload.string("an")) ?? "Find My"
        let footer = payload.string("ldtext").flatMap(\.nonEmpty)
        let location = findMyLocation(from: payload["URL"]).map { location in
            [
                "type": "LOCATION",
                "location": location.jsonObject,
            ]
        }
        return MessagePatch(textHeading: heading, textFooter: footer, extra: location)
    }

    func pollProps(from payloadData: Any) -> MessagePatch {
        guard let payload = unwrapDictionary(payloadData) else {
            return MessagePatch(textHeading: "Poll")
        }
        let text = pollText(from: pollPayload(from: payload["URL"]))
        return MessagePatch(
            text: text,
            textHeading: "Poll"
        )
    }

    func gamePigeonProps(from payloadData: Any) -> MessagePatch {
        guard let payload = unwrapDictionary(payloadData) else {
            return MessagePatch(textHeading: gamePigeonDisplayName)
        }
        let game = payload.string("ldtext")
        let caption = payload["userInfo"].flatMap(unwrapDictionary)?.string("caption")?.nonEmpty
        return MessagePatch(
            textHeading: gamePigeonHeading(for: game),
            textFooter: caption
        )
    }

    func parseSummaryInfo() -> JSONObject {
        guard let data = messageRow.messageSummaryInfo,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return [:]
        }
        return normalizeFoundationObject(plist) as? JSONObject ?? [:]
    }

    private func pluginPayloadAttachments(from attachments: [PlatformSDK.Attachment]) -> [PlatformSDK.Attachment] {
        attachments.filter {
            ($0.srcURL != nil)
                && ($0.fileName?.lowercased().hasSuffix(".pluginpayloadattachment") == true)
        }
    }

    private func richLinkAttachments(
        richLinkMetadata: JSONObject,
        payloadAttachments: [PlatformSDK.Attachment]
    ) -> [PlatformSDK.Attachment] {
        let alternateImages = richLinkMetadata.dictionary("alternateImages")?.array("NS.objects") ?? []
        let alternates = alternateImages.compactMap { alternate -> PlatformSDK.Attachment? in
            guard let index = (alternate as? JSONObject)?.int("richLinkImageAttachmentSubstituteIndex") else {
                return nil
            }
            return payloadAttachments[safe: index]
        }
        guard let videos = richLinkMetadata["videos"] else {
            return alternates
        }
        return externalVideos(from: videos) + alternates
    }

    private func tweetProps(
        richLinkMetadata: JSONObject,
        payloadAttachments: [PlatformSDK.Attachment],
        attachments: [PlatformSDK.Attachment],
        linkURL: String?,
        originalURL: String?
    ) -> MessagePatch? {
        guard let linkURL,
              isXHost(linkURL) || (originalURL.map(isXHost) ?? false),
              let originalURL,
              let parsedTweet = parseTweetURL(originalURL),
              let iconIndex = richLinkMetadata.dictionary("icon")?.int("richLinkImageAttachmentSubstituteIndex"),
              let imgURL = payloadAttachments[safe: iconIndex]?.srcURL else {
            return nil
        }
        let imageIndex = richLinkMetadata.dictionary("image")?.int("richLinkImageAttachmentSubstituteIndex")
        var tweetAttachments = imageIndex.flatMap { payloadAttachments[safe: $0].map { [$0] } } ?? []
        tweetAttachments.append(contentsOf: attachments)
        let text = unquote(richLinkMetadata.string("summary") ?? "")
        guard !tweetAttachments.isEmpty || !text.isEmpty else {
            return nil
        }
        let user = PlatformSDK.Tweet.User(
            imgURL: imgURL,
            name: richLinkMetadata.string("title")?.components(separatedBy: " on ").first ?? "",
            username: parsedTweet.username
        )
        return MessagePatch(tweets: [
            PlatformSDK.Tweet(
                id: parsedTweet.tweetID,
                user: user,
                text: text,
                url: linkURL,
                attachments: tweetAttachments
            ),
        ])
    }

    private func findMyLocation(from urlValue: Any?) -> FindMyLocation? {
        guard let url = relativeURL(urlValue),
              let encodedPayload = findMyQueryParameter("FindMyMessagePayloadZippedDataKey", in: url),
              let compressed = Data(base64Encoded: encodedPayload),
              let data = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let payload = try? JSONDecoder().decode(FindMyPayload.self, from: data) else {
            return nil
        }
        return payload.initialLocation
    }

    private func pollPayload(from urlValue: Any?) -> JSONObject? {
        guard let url = relativeURL(urlValue),
              let encodedPayload = dataURLPayload(from: url),
              let data = Data(base64Encoded: encodedPayload),
              let payload = try? JSONSerialization.jsonObject(with: data) as? JSONObject else {
            return nil
        }
        return payload
    }

    private func pollText(from payload: JSONObject?) -> String? {
        guard let item = payload?.dictionary("item") else {
            return nil
        }

        let title = item.string("title").flatMap(\.nonEmpty)
        let options = pollOptionLines(from: item)
        let optionList = options.isEmpty ? nil : options.joined(separator: "\n")
        let sections = [title, optionList].compactMap(\.self)

        guard !sections.isEmpty else {
            return nil
        }
        return sections.joined(separator: "\n\n")
    }

    private func pollOptionLines(from item: JSONObject) -> [String] {
        item.array("orderedPollOptions")
            .compactMap(pollOptionText)
            .enumerated()
            .map { offset, option in
                "\(offset + 1). \(option)"
            }
    }

    private func pollOptionText(from option: Any) -> String? {
        guard let option = option as? JSONObject else {
            return nil
        }
        return option.string("text").flatMap(\.nonEmpty)
            ?? option.string("attributedText").flatMap(\.nonEmpty)
    }

    func dataURLPayload(from url: String) -> String? {
        guard url.hasPrefix("data:"),
              let commaIndex = url.firstIndex(of: ",") else {
            return nil
        }
        let payloadStart = url.index(after: commaIndex)
        let payloadEnd = url[payloadStart...].firstIndex(of: "?") ?? url.endIndex
        let encoded = String(url[payloadStart ..< payloadEnd])
        return encoded.removingPercentEncoding ?? encoded
    }

    private func findMyQueryParameter(_ name: String, in url: String) -> String? {
        let componentsString = url.contains("?") ? url : "?\(url)"
        return URLComponents(string: componentsString)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}

private struct FindMyPayload: Decodable {
    let initialLocation: FindMyLocation
}

private struct FindMyLocation: Decodable {
    let latitude: Double
    let longitude: Double

    var jsonObject: JSONObject {
        [
            "latitude": latitude,
            "longitude": longitude,
        ]
    }
}
