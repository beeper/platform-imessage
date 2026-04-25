import Foundation

extension Mapper {
    func payloadData() -> Any? {
        guard let data = msgRow.dataURI("payload_data") else {
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

    func payloadProps(from payloadData: Any, messageAttachments: [JSONObject]) -> JSONObject {
        switch msgRow.string("balloon_bundle_id") {
        case BalloonBundleID.url, nil:
            return urlBalloonProps(from: payloadData, messageAttachments: messageAttachments)
        case BalloonBundleID.applePay:
            return applePayProps(from: payloadData)
        case BalloonBundleID.youtube:
            return youTubeProps(from: payloadData)
        default:
            return [:]
        }
    }

    func urlBalloonProps(from payloadData: Any, messageAttachments: [JSONObject]) -> JSONObject {
        guard let payload = payloadData as? JSONObject,
              let richLinkMetadata = payload.dictionary("richLinkMetadata") else {
            return [:]
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
        var link = compactDictionary([
            "img": imageAttachment?.string("srcURL"),
            "imgSize": imageAttachment?["size"],
            "url": linkURL,
            "title": richLinkMetadata.string("title"),
            "summary": richLinkMetadata.string("summary"),
        ])
        if link["img"] == nil,
           let iconIndex = richLinkMetadata.dictionary("icon")?.int("richLinkImageAttachmentSubstituteIndex"),
           let icon = payloadAttachments[safe: iconIndex] {
            link["favicon"] = icon.string("srcURL")
        }
        if link["img"] == nil, link["title"] == nil, link["summary"] == nil, link["favicon"] == nil {
            return [:]
        }
        return compactDictionary([
            "attachments": iframeURL == nil ? attachments : [],
            "links": [link],
            "iframeURL": iframeURL,
        ])
    }

    func externalVideos(from videos: Any?) -> [JSONObject] {
        guard let videos = videos as? JSONObject else {
            return []
        }
        return videos.array("NS.objects").compactMap { video -> JSONObject? in
            guard let video = video as? JSONObject,
                  video.string("type") != "text/html",
                  let srcURL = relativeURL(video["URL"]),
                  let size = parseSize(video.string("size")) else {
                return nil
            }
            return [
                "id": srcURL,
                "type": "video",
                "srcURL": srcURL,
                "size": size,
            ]
        }
    }

    func applePayProps(from payloadData: Any) -> JSONObject {
        guard let payload = payloadData as? JSONObject,
              let objects = payload["NS.objects"] as? [Any],
              let heading = objects.first as? String else {
            return [:]
        }
        return ["textHeading": heading]
    }

    func youTubeProps(from payloadData: Any) -> JSONObject {
        guard let unwrapped = unwrapDictionary(payloadData) else {
            return [:]
        }
        return [
            "attachments": [],
            "links": [[
                "title": unwrapped["ldtext"] as Any,
                "url": relativeURL(unwrapped["URL"]) as Any,
            ].compactMapValues { value in
                value is NSNull ? nil : value
            }],
        ]
    }

    func parseSummaryInfo() -> JSONObject {
        guard let data = msgRow.dataURI("message_summary_info"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return [:]
        }
        return normalizeFoundationObject(plist) as? JSONObject ?? [:]
    }

    private func pluginPayloadAttachments(from attachments: [JSONObject]) -> [JSONObject] {
        attachments.filter {
            ($0.string("srcURL") != nil)
                && ($0.string("fileName")?.lowercased().hasSuffix(".pluginpayloadattachment") == true)
        }
    }

    private func richLinkAttachments(
        richLinkMetadata: JSONObject,
        payloadAttachments: [JSONObject]
    ) -> [JSONObject] {
        let alternateImages = richLinkMetadata.dictionary("alternateImages")?.array("NS.objects") ?? []
        let alternates = alternateImages.compactMap { alternate -> JSONObject? in
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
        payloadAttachments: [JSONObject],
        attachments: [JSONObject],
        linkURL: String?,
        originalURL: String?
    ) -> JSONObject? {
        guard let linkURL,
              isXHost(linkURL) || (originalURL.map(isXHost) ?? false),
              let parsedTweet = parseTweetURL(originalURL ?? linkURL),
              let iconIndex = richLinkMetadata.dictionary("icon")?.int("richLinkImageAttachmentSubstituteIndex"),
              let imgURL = payloadAttachments[safe: iconIndex]?.string("srcURL") else {
            return nil
        }
        let imageIndex = richLinkMetadata.dictionary("image")?.int("richLinkImageAttachmentSubstituteIndex")
        var tweetAttachments = imageIndex.flatMap { payloadAttachments[safe: $0].map { [$0] } } ?? []
        tweetAttachments.append(contentsOf: attachments)
        let tweet = compactDictionary([
            "id": parsedTweet.tweetID,
            "user": compactDictionary([
                "username": parsedTweet.username,
                "imgURL": imgURL,
                "name": richLinkMetadata.string("title")?.components(separatedBy: " on ").first,
            ]),
            "url": linkURL,
            "text": unquote(richLinkMetadata.string("summary") ?? ""),
            "attachments": tweetAttachments,
        ])
        guard !tweetAttachments.isEmpty || !(tweet.string("text") ?? "").isEmpty else {
            return nil
        }
        return ["tweets": [tweet]]
    }
}
