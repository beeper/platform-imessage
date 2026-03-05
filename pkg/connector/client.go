//go:build darwin

package connector

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"go.mau.fi/util/jsontime"
	"go.mau.fi/util/ptr"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/event"
)

const (
	BridgeStateConnectError status.BridgeStateErrorCode = "imessage-connect-error"
)

type IMClient struct {
	Main      *IMConnector
	UserLogin *bridgev2.UserLogin
	Metadata  *UserLoginMetadata

	loggedIn bool
}

var (
	_ bridgev2.NetworkAPI                    = (*IMClient)(nil)
	_ bridgev2.IdentifierResolvingNetworkAPI = (*IMClient)(nil)
	_ bridgev2.ReadReceiptHandlingNetworkAPI = (*IMClient)(nil)
	_ bridgev2.TypingHandlingNetworkAPI      = (*IMClient)(nil)
	_ bridgev2.DeleteChatHandlingNetworkAPI  = (*IMClient)(nil)
	_ bridgev2.EditHandlingNetworkAPI        = (*IMClient)(nil)
	_ bridgev2.ReactionHandlingNetworkAPI    = (*IMClient)(nil)
	_ bridgev2.RedactionHandlingNetworkAPI   = (*IMClient)(nil)
)

var imessageRoomCaps = &event.RoomFeatures{
	ID: "com.beeper.imessage.capabilities",
	File: map[event.CapabilityMsgType]*event.FileFeatures{
		event.MsgFile: {
			MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported},
			MaxSize:   100 * 1024 * 1024,
		},
		event.MsgImage: {
			MimeTypes: map[string]event.CapabilitySupportLevel{
				"image/jpeg": event.CapLevelFullySupported,
				"image/png":  event.CapLevelFullySupported,
				"image/gif":  event.CapLevelFullySupported,
				"image/webp": event.CapLevelFullySupported,
			},
			MaxSize: 100 * 1024 * 1024,
		},
		event.MsgAudio: {
			MimeTypes: map[string]event.CapabilitySupportLevel{
				"audio/mpeg": event.CapLevelFullySupported,
				"audio/mp4":  event.CapLevelFullySupported,
				"audio/ogg":  event.CapLevelFullySupported,
				"audio/wav":  event.CapLevelFullySupported,
				"audio/webm": event.CapLevelFullySupported,
				"audio/aac":  event.CapLevelFullySupported,
			},
			MaxSize: 100 * 1024 * 1024,
		},
		event.MsgVideo: {
			MimeTypes: map[string]event.CapabilitySupportLevel{
				"video/mp4":  event.CapLevelFullySupported,
				"video/webm": event.CapLevelFullySupported,
				"video/ogg":  event.CapLevelFullySupported,
			},
			MaxSize: 100 * 1024 * 1024,
		},
	},
	Reply:               event.CapLevelFullySupported,
	Edit:                event.CapLevelFullySupported,
	EditMaxCount:        5,
	EditMaxAge:          ptr.Ptr(jsontime.SInt(15 * 60)),
	Delete:              event.CapLevelFullySupported,
	DeleteMaxAge:        ptr.Ptr(jsontime.SInt(2 * 60)),
	Reaction:            event.CapLevelFullySupported,
	ReactionCount:       1,
	AllowedReactions:    []string{"❤️", "👍", "👎", "😂", "‼️", "❓"},
	ReadReceipts:        true,
	TypingNotifications: true,
	DeleteChat:          true,
}

func (ic *IMClient) Connect(ctx context.Context) {
	var currentUser JSCurrentUser
	err := ic.Main.bridgeCLI().Run(ctx, "get-current-user", nil, &currentUser)
	if err != nil {
		ic.loggedIn = false
		ic.UserLogin.BridgeState.Send(status.BridgeState{
			UserID:     ic.UserLogin.UserMXID,
			RemoteName: ic.UserLogin.RemoteName,
			StateEvent: status.StateUnknownError,
			Error:      BridgeStateConnectError,
			Info:       map[string]any{"go_error": err.Error()},
			Timestamp:  jsontime.UnixNow(),
		})
		return
	}

	ic.loggedIn = true
	ic.UserLogin.BridgeState.Send(status.BridgeState{
		UserID:     ic.UserLogin.UserMXID,
		RemoteName: currentUser.DisplayName,
		StateEvent: status.StateConnected,
		Timestamp:  jsontime.UnixNow(),
	})
}

func (ic *IMClient) Disconnect() {}

func (ic *IMClient) IsLoggedIn() bool {
	return ic.loggedIn
}

func (ic *IMClient) LogoutRemote(ctx context.Context) {
	ic.loggedIn = false
}

func (ic *IMClient) IsThisUser(ctx context.Context, userID networkid.UserID) bool {
	if ic.Metadata == nil {
		return false
	}

	stringID := string(userID)
	return stringID == ic.Metadata.CurrentUserID || stringID == ic.Metadata.Email || stringID == ic.Metadata.PhoneNumber
}

func (ic *IMClient) GetChatInfo(ctx context.Context, portal *bridgev2.Portal) (*bridgev2.ChatInfo, error) {
	var thread JSThread
	err := ic.Main.bridgeCLI().Run(ctx, "get-thread", map[string]string{
		"threadID": string(portal.ID),
	}, &thread)
	if err == nil && thread.ID != "" {
		roomType := database.RoomTypeDM
		if thread.IsGroup {
			roomType = database.RoomTypeDefault
		}
		return &bridgev2.ChatInfo{
			Name: ptr.Ptr(firstNonEmpty(thread.Title, thread.ID)),
			Type: ptr.Ptr(roomType),
		}, nil
	}

	identifier := threadIDToIdentifier(string(portal.ID))
	roomType := database.RoomTypeDM
	return &bridgev2.ChatInfo{
		Name: ptr.Ptr(firstNonEmpty(identifier, string(portal.ID))),
		Type: ptr.Ptr(roomType),
	}, nil
}

func (ic *IMClient) GetUserInfo(ctx context.Context, ghost *bridgev2.Ghost) (*bridgev2.UserInfo, error) {
	identifier := string(ghost.ID)
	displayName := identifier
	identifiers := []string{identifier}
	return &bridgev2.UserInfo{
		Name:        &displayName,
		Identifiers: identifiers,
	}, nil
}

func (ic *IMClient) GetCapabilities(ctx context.Context, portal *bridgev2.Portal) *event.RoomFeatures {
	return imessageRoomCaps
}

func (ic *IMClient) HandleMatrixMessage(ctx context.Context, msg *bridgev2.MatrixMessage) (*bridgev2.MatrixMessageResponse, error) {
	payload := map[string]string{
		"threadID": string(msg.Portal.ID),
	}

	switch msg.Content.MsgType {
	case event.MsgText, event.MsgNotice:
		payload["text"] = msg.Content.Body
	case event.MsgEmote:
		payload["text"] = "/me " + msg.Content.Body
	case event.MsgImage, event.MsgAudio, event.MsgVideo, event.MsgFile:
		tmpFilePath, err := ic.downloadMediaToTempFile(ctx, msg)
		if err != nil {
			return nil, err
		}
		defer os.Remove(tmpFilePath)

		payload["filePath"] = tmpFilePath
		payload["fileName"] = msg.Content.FileName
	default:
		return nil, fmt.Errorf("%w %s", bridgev2.ErrUnsupportedMessageType, msg.Content.MsgType)
	}

	if msg.ReplyTo != nil {
		payload["quotedMessageID"] = string(msg.ReplyTo.ID)
	}

	var response JSSendMessageResponse
	if err := ic.Main.bridgeCLI().Run(ctx, "send-message", payload, &response); err != nil {
		return nil, err
	}

	dbMessage := &database.Message{
		SenderID:  networkid.UserID(ic.UserLogin.ID),
		Timestamp: time.Now(),
	}
	if len(response.Messages) > 0 {
		dbMessage.ID = networkid.MessageID(response.Messages[0].ID)
		if response.Messages[0].TimestampMS > 0 {
			dbMessage.Timestamp = time.UnixMilli(response.Messages[0].TimestampMS)
		}
	} else if msg.InputTransactionID != "" {
		dbMessage.ID = networkid.MessageID(msg.InputTransactionID)
	} else {
		dbMessage.ID = networkid.MessageID(fmt.Sprintf("imessage-%d", time.Now().UnixNano()))
	}

	return &bridgev2.MatrixMessageResponse{
		DB: dbMessage,
	}, nil
}

func (ic *IMClient) HandleMatrixEdit(ctx context.Context, msg *bridgev2.MatrixEdit) error {
	return ic.Main.bridgeCLI().Run(ctx, "edit-message", map[string]string{
		"threadID":  string(msg.Portal.ID),
		"messageID": string(msg.EditTarget.ID),
		"text":      msg.Content.Body,
	}, nil)
}

func (ic *IMClient) PreHandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (bridgev2.MatrixReactionPreResponse, error) {
	return bridgev2.MatrixReactionPreResponse{
		SenderID:     networkid.UserID(ic.UserLogin.ID),
		Emoji:        msg.Content.RelatesTo.Key,
		MaxReactions: 1,
	}, nil
}

func (ic *IMClient) HandleMatrixReaction(ctx context.Context, msg *bridgev2.MatrixReaction) (*database.Reaction, error) {
	err := ic.Main.bridgeCLI().Run(ctx, "send-reaction", map[string]string{
		"threadID":    string(msg.Portal.ID),
		"messageID":   string(msg.TargetMessage.ID),
		"reactionKey": msg.PreHandleResp.Emoji,
	}, nil)
	if err != nil {
		return nil, err
	}
	return &database.Reaction{}, nil
}

func (ic *IMClient) HandleMatrixReactionRemove(ctx context.Context, msg *bridgev2.MatrixReactionRemove) error {
	return ic.Main.bridgeCLI().Run(ctx, "remove-reaction", map[string]string{
		"threadID":    string(msg.Portal.ID),
		"messageID":   string(msg.TargetReaction.MessageID),
		"reactionKey": msg.TargetReaction.Emoji,
	}, nil)
}

func (ic *IMClient) HandleMatrixMessageRemove(ctx context.Context, msg *bridgev2.MatrixMessageRemove) error {
	return ic.Main.bridgeCLI().Run(ctx, "delete-message", map[string]string{
		"threadID":  string(msg.Portal.ID),
		"messageID": string(msg.TargetMessage.ID),
	}, nil)
}

func (ic *IMClient) HandleMatrixReadReceipt(ctx context.Context, msg *bridgev2.MatrixReadReceipt) error {
	payload := map[string]string{
		"threadID": string(msg.Portal.ID),
	}
	if msg.ExactMessage != nil {
		payload["messageID"] = string(msg.ExactMessage.ID)
	}
	return ic.Main.bridgeCLI().Run(ctx, "send-read-receipt", payload, nil)
}

func (ic *IMClient) HandleMatrixTyping(ctx context.Context, msg *bridgev2.MatrixTyping) error {
	return ic.Main.bridgeCLI().Run(ctx, "send-typing", map[string]any{
		"threadID": string(msg.Portal.ID),
		"isTyping": msg.IsTyping,
	}, nil)
}

func (ic *IMClient) HandleMatrixDeleteChat(ctx context.Context, msg *bridgev2.MatrixDeleteChat) error {
	return ic.Main.bridgeCLI().Run(ctx, "delete-thread", map[string]string{
		"threadID": string(msg.Portal.ID),
	}, nil)
}

func (ic *IMClient) ResolveIdentifier(ctx context.Context, identifier string, createChat bool) (*bridgev2.ResolveIdentifierResponse, error) {
	identifier = strings.TrimSpace(identifier)
	if identifier == "" {
		return nil, fmt.Errorf("identifier cannot be empty")
	}

	userID := networkid.UserID(identifier)
	ghost, err := ic.UserLogin.Bridge.GetGhostByID(ctx, userID)
	if err != nil {
		return nil, fmt.Errorf("get ghost: %w", err)
	}

	userInfo, _ := ic.GetUserInfo(ctx, ghost)
	resp := &bridgev2.ResolveIdentifierResponse{
		Ghost:    ghost,
		UserID:   userID,
		UserInfo: userInfo,
	}

	if createChat {
		portalKey := networkid.PortalKey{
			ID:       networkid.PortalID(makeDMThreadID(identifier)),
			Receiver: ic.UserLogin.ID,
		}
		resp.Chat = &bridgev2.CreateChatResponse{
			PortalKey: portalKey,
			PortalInfo: &bridgev2.ChatInfo{
				Name: ptr.Ptr(identifier),
				Type: ptr.Ptr(database.RoomTypeDM),
			},
		}
	}

	return resp, nil
}

func (ic *IMClient) downloadMediaToTempFile(ctx context.Context, msg *bridgev2.MatrixMessage) (string, error) {
	data, err := ic.Main.Bridge.Bot.DownloadMedia(ctx, msg.Content.URL, msg.Content.File)
	if err != nil {
		return "", fmt.Errorf("%w: %w", bridgev2.ErrMediaDownloadFailed, err)
	}

	pattern := "imessage-*"
	if msg.Content.FileName != "" {
		pattern = "imessage-" + filepath.Base(msg.Content.FileName)
	}
	tmpFile, err := os.CreateTemp("", pattern)
	if err != nil {
		return "", fmt.Errorf("create temp media file: %w", err)
	}
	defer tmpFile.Close()

	if _, err = tmpFile.Write(data); err != nil {
		return "", fmt.Errorf("write temp media file: %w", err)
	}
	return tmpFile.Name(), nil
}

func threadIDToIdentifier(threadID string) string {
	parts := strings.SplitN(threadID, ";-;", 2)
	if len(parts) == 2 {
		return parts[1]
	}
	return threadID
}

func makeDMThreadID(identifier string) string {
	return "iMessage;-;" + identifier
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
