package connector

import (
	"context"
	"time"

	"go.mau.fi/util/jsontime"
	"go.mau.fi/util/ptr"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/event"
)

const maxTextLength = 200_000
const maxFileSize = 100 * 1024 * 1024

var supportedIMessageReactions = []string{"❤️", "👍", "👎", "HAHA", "‼️", "❓"}

var generalCaps = &bridgev2.NetworkGeneralCapabilities{
	ImplicitReadReceipts: false,
	Provisioning: bridgev2.ProvisioningCapabilities{
		ResolveIdentifier: bridgev2.ResolveIdentifierCapabilities{
			CreateDM:    true,
			LookupEmail: true,
			AnyPhone:    true,
			ContactList: true,
			Search:      true,
		},
		GroupCreation: map[string]bridgev2.GroupTypeCapabilities{
			"group": {
				TypeDescription: "iMessage group",
				Name: bridgev2.GroupFieldCapability{
					Allowed: true,
				},
				Participants: bridgev2.GroupFieldCapability{
					Allowed:   true,
					Required:  true,
					MinLength: 2,
				},
			},
		},
	},
}

func (c *Connector) GetCapabilities() *bridgev2.NetworkGeneralCapabilities {
	return generalCaps
}

func (c *Connector) GetBridgeInfoVersion() (info, capabilities int) {
	return 1, 2
}

var roomCaps = &event.RoomFeatures{
	ID: "com.beeper.imessage.capabilities.2026_06_05",
	Formatting: map[event.FormattingFeature]event.CapabilitySupportLevel{
		event.FmtBold:          event.CapLevelDropped,
		event.FmtItalic:        event.CapLevelDropped,
		event.FmtStrikethrough: event.CapLevelDropped,
		event.FmtInlineLink:    event.CapLevelDropped,
		event.FmtUserLink:      event.CapLevelDropped,
	},
	File: map[event.CapabilityMsgType]*event.FileFeatures{
		event.MsgImage: {
			MimeTypes: map[string]event.CapabilitySupportLevel{
				"image/jpeg": event.CapLevelFullySupported,
				"image/png":  event.CapLevelFullySupported,
				"image/gif":  event.CapLevelFullySupported,
				"image/webp": event.CapLevelFullySupported,
			},
			Caption: event.CapLevelDropped,
			MaxSize: maxFileSize,
		},
		event.MsgVideo: {
			MimeTypes: map[string]event.CapabilitySupportLevel{
				"video/mp4":  event.CapLevelFullySupported,
				"video/webm": event.CapLevelFullySupported,
				"video/ogg":  event.CapLevelFullySupported,
			},
			Caption: event.CapLevelDropped,
			MaxSize: maxFileSize,
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
			Caption: event.CapLevelDropped,
			MaxSize: maxFileSize,
		},
		event.MsgFile: {
			MimeTypes: map[string]event.CapabilitySupportLevel{"*/*": event.CapLevelFullySupported},
			Caption:   event.CapLevelDropped,
			MaxSize:   maxFileSize,
		},
	},
	MaxTextLength:        maxTextLength,
	Reply:                event.CapLevelFullySupported,
	Edit:                 event.CapLevelFullySupported,
	EditMaxAge:           ptr.Ptr(jsontime.S(15 * time.Minute)),
	Delete:               event.CapLevelFullySupported,
	DeleteForMe:          false,
	DeleteMaxAge:         ptr.Ptr(jsontime.S(2 * time.Minute)),
	Reaction:             event.CapLevelFullySupported,
	ReactionCount:        1,
	AllowedReactions:     supportedIMessageReactions,
	CustomEmojiReactions: false,
	ReadReceipts:         true,
	TypingNotifications:  true,
	MarkAsUnread:         true,
	DeleteChat:           true,
}

func (c *Client) GetCapabilities(ctx context.Context, portal *bridgev2.Portal) *event.RoomFeatures {
	caps := roomCaps.Clone()
	if portal != nil && len(recipientsFromThreadID(string(portal.ID))) > 0 {
		caps.ID = "com.beeper.imessage.capabilities.2026_06_05.synthetic"
		caps.File = nil
	}
	return caps
}
