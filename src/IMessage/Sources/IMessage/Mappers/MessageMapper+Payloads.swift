import Foundation
import PlatformSDK

extension Mapper {
    func payloadData() -> Any? {
        guard let data = msgRow.payloadData else {
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

    func payloadProps(from payloadData: Any, messageAttachments: [PlatformSDK.Attachment]) -> MessagePatch {
        switch msgRow.balloonBundleID {
        case BalloonBundleID.url, nil:
            return urlBalloonProps(from: payloadData, messageAttachments: messageAttachments)
        case BalloonBundleID.applePay:
            return applePayProps(from: payloadData)
        case BalloonBundleID.youtube:
            return youTubeProps(from: payloadData)
        default:
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
                size: PlatformSDK.Size(width: Double(size["width"] ?? 0), height: Double(size["height"] ?? 0)),
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

    func parseSummaryInfo() -> JSONObject {
        guard let data = msgRow.messageSummaryInfo,
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
}
