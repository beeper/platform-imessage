package connector

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/event"
)

func (c *Client) convertMessageFromIMessage(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, msg imessage.Message) (*bridgev2.ConvertedMessage, error) {
	converted := &bridgev2.ConvertedMessage{
		ReplyTo: replyTarget(msg),
	}

	if strings.TrimSpace(msg.Text) != "" || len(msg.Attachments) == 0 {
		content := c.messageTextContentFromIMessage(ctx, msg)
		converted.Parts = append(converted.Parts, &bridgev2.ConvertedMessagePart{
			Type:       event.EventMessage,
			Content:    content,
			DBMetadata: messageDBMetadata(msg),
		})
	}

	for _, attachment := range msg.Attachments {
		part, err := c.convertAttachmentFromIMessage(ctx, portal, intent, msg, attachment)
		if err != nil {
			part = unavailableAttachmentPart(msg, attachment, err)
		}
		converted.Parts = append(converted.Parts, part)
	}

	if len(converted.Parts) == 0 {
		content := c.messageTextContentFromIMessage(ctx, msg)
		converted.Parts = append(converted.Parts, &bridgev2.ConvertedMessagePart{
			Type:       event.EventMessage,
			Content:    content,
			DBMetadata: messageDBMetadata(msg),
		})
	}
	setConvertedMessagePartIDs(converted.Parts)
	return converted, nil
}

func setConvertedMessagePartIDs(parts []*bridgev2.ConvertedMessagePart) {
	for i, part := range parts {
		if part != nil {
			part.ID = imessageid.MakePartID(i)
		}
	}
}

func (c *Client) convertAttachmentFromIMessage(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, msg imessage.Message, attachment imessage.Attachment) (*bridgev2.ConvertedMessagePart, error) {
	data, fileName, mimeType, err := c.attachmentBytes(ctx, msg, attachment)
	if err != nil {
		return nil, err
	}
	mxc, file, err := intent.UploadMedia(ctx, portal.MXID, data, fileName, mimeType)
	if err != nil {
		return nil, err
	}
	info := fileInfoForAttachment(data, attachment, mimeType)
	return &bridgev2.ConvertedMessagePart{
		Type: event.EventMessage,
		Content: &event.MessageEventContent{
			MsgType:  msgTypeForAttachment(attachment, mimeType),
			Body:     fileName,
			FileName: fileName,
			URL:      mxc,
			File:     file,
			Info:     info,
		},
		DBMetadata: messageDBMetadata(msg),
	}, nil
}

func fileInfoForAttachment(data []byte, attachment imessage.Attachment, mimeType string) *event.FileInfo {
	info := &event.FileInfo{
		MimeType: mimeType,
		Size:     len(data),
		MauGIF:   attachment.IsGif,
	}
	if width, height := imageDimensions(data, mimeType); width > 0 && height > 0 {
		info.Width = width
		info.Height = height
	}
	return info
}

func imageDimensions(data []byte, mimeType string) (width, height int) {
	if !strings.HasPrefix(mimeType, "image/") || len(data) == 0 {
		return 0, 0
	}
	config, _, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return 0, 0
	}
	return config.Width, config.Height
}

func (c *Client) attachmentBytes(ctx context.Context, msg imessage.Message, attachment imessage.Attachment) ([]byte, string, string, error) {
	if attachment.SrcURL == "" {
		if err := c.IM.LoadAttachment(msg.ID); err != nil {
			return nil, "", "", err
		}
		reloaded, err := c.IM.Chat(msg.ThreadID)
		if err != nil {
			return nil, "", "", err
		}
		if reloaded != nil && reloaded.PartialLastMessage != nil && reloaded.PartialLastMessage.ID == msg.ID {
			for _, loadedAttachment := range reloaded.PartialLastMessage.Attachments {
				if loadedAttachment.ID == attachment.ID && loadedAttachment.SrcURL != "" {
					attachment = loadedAttachment
					break
				}
			}
		}
		if attachment.SrcURL == "" {
			page, err := c.IM.Messages(msg.ThreadID, nil)
			if err != nil {
				return nil, "", "", err
			}
			for _, loadedMessage := range page.Items {
				if loadedMessage.ID != msg.ID {
					continue
				}
				for _, loadedAttachment := range loadedMessage.Attachments {
					if loadedAttachment.ID == attachment.ID && loadedAttachment.SrcURL != "" {
						attachment = loadedAttachment
						break
					}
				}
			}
		}
		if attachment.SrcURL == "" {
			return nil, "", "", fmt.Errorf("attachment %s has no source URL after load request", attachment.ID)
		}
	}
	data, path, err := c.readAttachmentURL(ctx, attachment.SrcURL, 0)
	if err != nil {
		return nil, "", "", err
	}

	fileName := attachment.FileName
	if fileName == "" {
		fileName = filepath.Base(path)
	}
	if fileName == "" || fileName == "." || fileName == "/" {
		fileName = attachment.ID
	}
	mimeType := attachment.MimeType
	if mimeType == "" {
		mimeType = mime.TypeByExtension(filepath.Ext(fileName))
	}
	if mimeType == "" {
		mimeType = http.DetectContentType(data)
	}
	return data, fileName, mimeType, nil
}

func (c *Client) readAttachmentURL(ctx context.Context, rawURL string, depth int) ([]byte, string, error) {
	if depth > 4 {
		return nil, "", fmt.Errorf("too many nested asset redirects")
	}
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, "", err
	}
	switch parsed.Scheme {
	case "file":
		return readLocalAttachmentFile(parsed.Path)
	case "asset":
		pathHex, methodName := splitAssetPath(strings.TrimPrefix(parsed.Path, "/"))
		asset, err := c.IM.GetAsset(pathHex, methodName)
		if err != nil {
			return nil, "", err
		}
		if asset.DataBase64 != "" {
			data, err := base64.StdEncoding.DecodeString(asset.DataBase64)
			return data, methodName, err
		}
		if asset.URL != "" {
			return c.readAttachmentURL(ctx, asset.URL, depth+1)
		}
		return nil, "", fmt.Errorf("asset %s returned no URL or data", rawURL)
	case "":
		return readLocalAttachmentFile(rawURL)
	default:
		return nil, "", fmt.Errorf("unsupported attachment URL scheme %q", parsed.Scheme)
	}
}

func readLocalAttachmentFile(path string) ([]byte, string, error) {
	data, err := os.ReadFile(path)
	return data, path, err
}

func splitAssetPath(path string) (pathHex, methodName string) {
	parts := strings.SplitN(path, "/", 2)
	pathHex = parts[0]
	if len(parts) > 1 {
		methodName = parts[1]
	}
	return
}

func unavailableAttachmentPart(msg imessage.Message, attachment imessage.Attachment, err error) *bridgev2.ConvertedMessagePart {
	fileName := attachment.FileName
	if fileName == "" {
		fileName = attachment.ID
	}
	return &bridgev2.ConvertedMessagePart{
		Type: event.EventMessage,
		Content: &event.MessageEventContent{
			MsgType: event.MsgNotice,
			Body:    fmt.Sprintf("Attachment unavailable: %s (%v)", fileName, err),
		},
		DBMetadata: messageDBMetadata(msg),
	}
}

func msgTypeForAttachment(attachment imessage.Attachment, mimeType string) event.MessageType {
	if attachment.IsSticker {
		return event.MsgImage
	}
	switch {
	case strings.HasPrefix(mimeType, "image/"):
		return event.MsgImage
	case strings.HasPrefix(mimeType, "video/"):
		return event.MsgVideo
	case strings.HasPrefix(mimeType, "audio/"):
		return event.MsgAudio
	default:
		return event.MsgFile
	}
}

func messageDBMetadata(msg imessage.Message) *imessageid.MessageMetadata {
	meta := &imessageid.MessageMetadata{
		ThreadID:   msg.ThreadID,
		Cursor:     msg.Cursor,
		Attachment: len(msg.Attachments) > 0,
	}
	for _, attachment := range msg.Attachments {
		if attachment.ID != "" {
			meta.AttachmentIDs = append(meta.AttachmentIDs, attachment.ID)
		}
		if attachment.SrcURL != "" {
			meta.AttachmentURLs = append(meta.AttachmentURLs, attachment.SrcURL)
		}
	}
	return meta
}

func (c *Client) mentionsFromIMessage(ctx context.Context, msg imessage.Message) *event.Mentions {
	if msg.TextAttributes == nil {
		return nil
	}
	mentions := &event.Mentions{}
	for _, entity := range msg.TextAttributes.Entities {
		if entity.MentionedUser == nil || entity.MentionedUser.ID == "" {
			continue
		}
		ghost, err := c.Main.Bridge.GetGhostByID(ctx, imessageid.MakeUserID(entity.MentionedUser.ID))
		if err != nil || ghost == nil {
			continue
		}
		mentions.Add(ghost.Intent.GetMXID())
	}
	if len(mentions.UserIDs) == 0 && !mentions.Room {
		return nil
	}
	return mentions
}
