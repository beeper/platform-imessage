package connector

import (
	"context"
	"encoding/base64"
	"fmt"
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
		converted.Parts = append(converted.Parts, &bridgev2.ConvertedMessagePart{
			Type:       event.EventMessage,
			Content:    messageTextContentFromIMessage(msg),
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
		converted.Parts = append(converted.Parts, &bridgev2.ConvertedMessagePart{
			Type:       event.EventMessage,
			Content:    messageTextContentFromIMessage(msg),
			DBMetadata: messageDBMetadata(msg),
		})
	}
	return converted, nil
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
	return &bridgev2.ConvertedMessagePart{
		Type: event.EventMessage,
		Content: &event.MessageEventContent{
			MsgType:  msgTypeForAttachment(attachment, mimeType),
			Body:     fileName,
			FileName: fileName,
			URL:      mxc,
			File:     file,
			Info: &event.FileInfo{
				MimeType: mimeType,
				Size:     len(data),
				MauGIF:   attachment.IsGif,
			},
		},
		DBMetadata: messageDBMetadata(msg),
	}, nil
}

func (c *Client) attachmentBytes(ctx context.Context, msg imessage.Message, attachment imessage.Attachment) ([]byte, string, string, error) {
	if attachment.SrcURL == "" {
		if err := c.IM.LoadAttachment(msg.ID); err != nil {
			return nil, "", "", err
		}
		return nil, "", "", fmt.Errorf("attachment %s has no source URL after load request", attachment.ID)
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
