package connector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/simplevent"
	"maunium.net/go/mautrix/bridgev2/status"
)

type Client struct {
	Main      *Connector
	UserLogin *bridgev2.UserLogin
	IM        *imessage.Client

	stopEventLock sync.Mutex
	stopEventLoop chan struct{}
	loggedIn      atomic.Bool
}

var _ bridgev2.NetworkAPI = (*Client)(nil)
var _ bridgev2.NetworkAPIWithUserID = (*Client)(nil)

func (c *Client) Connect(ctx context.Context) {
	c.loggedIn.Store(false)
	c.UserLogin.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnecting})
	authStatus, err := c.IM.AuthorizationStatus()
	if err != nil {
		c.UserLogin.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateBadCredentials,
			Error:      "IMESSAGE_PERMISSION_CHECK_FAILED",
			Message:    err.Error(),
		})
		return
	}
	if !authStatus.Authorized {
		c.UserLogin.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateBadCredentials,
			Error:      "IMESSAGE_PERMISSIONS_MISSING",
			Message:    missingPermissionMessage(authStatus),
		})
		return
	}
	if _, err := c.IM.CurrentUser(); err != nil {
		c.UserLogin.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateBadCredentials,
			Error:      "IMESSAGE_NOT_AVAILABLE",
			Message:    err.Error(),
		})
		return
	}
	stopEventLoop := c.resetEventLoop()
	c.loggedIn.Store(true)
	c.UserLogin.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnected})

	if err := c.IM.StartEvents(); err != nil {
		c.UserLogin.Log.Warn().Err(err).Msg("Failed to start iMessage event watcher")
		return
	}
	go c.syncExistingChats()
	go c.eventLoop(stopEventLoop)
}

func missingPermissionMessage(authStatus *imessage.AuthorizationStatus) string {
	if authStatus == nil {
		return "Local iMessage permissions are missing"
	}
	var missing []string
	for _, permission := range authStatus.Permissions {
		if permission.Required && !permission.Authorized {
			missing = append(missing, permission.Title)
		}
	}
	if len(missing) == 0 {
		return "Local iMessage permissions are missing"
	}
	return "Missing local iMessage permissions: " + strings.Join(missing, ", ")
}

func (c *Client) Disconnect() {
	c.loggedIn.Store(false)
	c.stopEventLock.Lock()
	defer c.stopEventLock.Unlock()
	if c.stopEventLoop != nil {
		close(c.stopEventLoop)
		c.stopEventLoop = nil
	}
}

func (c *Client) IsLoggedIn() bool {
	return c.loggedIn.Load()
}

func (c *Client) LogoutRemote(ctx context.Context) {
	c.Disconnect()
}

func (c *Client) IsThisUser(ctx context.Context, userID networkid.UserID) bool {
	return userID == c.GetUserID()
}

func (c *Client) GetUserID() networkid.UserID {
	return imessageid.MakeUserID(string(c.UserLogin.ID))
}

func (c *Client) resetEventLoop() <-chan struct{} {
	c.stopEventLock.Lock()
	defer c.stopEventLock.Unlock()
	if c.stopEventLoop != nil {
		close(c.stopEventLoop)
	}
	c.stopEventLoop = make(chan struct{})
	return c.stopEventLoop
}

func (c *Client) eventLoop(stopEventLoop <-chan struct{}) {
	timeout := c.Main.Config.EventPollTimeoutMS
	if timeout <= 0 {
		timeout = 30000
	}

	for {
		select {
		case <-stopEventLoop:
			return
		default:
		}

		events, err := c.IM.NextEvents(timeout)
		if err != nil {
			c.UserLogin.Log.Warn().Err(err).Msg("Failed to poll iMessage events")
			time.Sleep(5 * time.Second)
			continue
		}
		for _, evt := range events {
			if err := c.handleStateSyncEvent(evt); err != nil {
				c.UserLogin.Log.Warn().Err(err).Msg("Failed to handle iMessage event")
			}
		}
	}
}

func (c *Client) handleStateSyncEvent(evt imessage.StateSyncEvent) error {
	if evt.Type != "state_sync" {
		if evt.Type == "user_activity" {
			c.handleUserActivity(evt)
		}
		return nil
	}
	switch evt.ObjectName {
	case "message":
		return c.handleMessageStateSync(evt)
	case "message_reaction":
		return c.handleReactionStateSync(evt)
	case "thread":
		return c.handleThreadStateSync(evt)
	default:
		return nil
	}
}

func (c *Client) handleUserActivity(evt imessage.StateSyncEvent) {
	if evt.ThreadID == "" || evt.ParticipantID == "" {
		return
	}
	timeout := 120 * time.Second
	if evt.DurationMS > 0 {
		timeout = time.Duration(evt.DurationMS) * time.Millisecond
	}
	if evt.ActivityType != "typing" {
		timeout = 0
	}
	meta := c.baseEventMeta(evt.ThreadID).WithType(bridgev2.RemoteEventTyping)
	meta.Sender = bridgev2.EventSender{Sender: imessageid.MakeUserID(evt.ParticipantID)}
	c.UserLogin.QueueRemoteEvent(&simplevent.Typing{
		EventMeta: meta,
		Timeout:   timeout,
		Type:      bridgev2.TypingTypeText,
	})
}

func (c *Client) syncExistingChats() {
	page, err := c.IM.Chats(nil)
	if err != nil {
		c.UserLogin.Log.Warn().Err(err).Msg("Failed to sync iMessage chats")
		return
	}
	for _, thread := range page.Items {
		thread := thread
		c.reIDKnownSyntheticPortals(context.Background(), thread)
		c.queueThreadReadState(thread)
		c.UserLogin.QueueRemoteEvent(&simplevent.ChatResync{
			EventMeta: c.baseEventMeta(thread.ID).WithType(bridgev2.RemoteEventChatResync),
			ChatInfo:  c.chatInfoFromThread(thread),
		})
		messages, err := c.IM.Messages(thread.ID, nil)
		if err != nil {
			c.UserLogin.Log.Warn().Err(err).Str("thread_id", thread.ID).Msg("Failed to sync iMessage messages")
			continue
		}
		for i := len(messages.Items) - 1; i >= 0; i-- {
			message := messages.Items[i]
			evt := imessage.StateSyncEvent{
				Type:         "state_sync",
				ObjectName:   "message",
				MutationType: "upsert",
			}
			evt.Entries, _ = json.Marshal([]imessage.Message{message})
			if err := c.handleMessageStateSync(evt); err != nil {
				c.UserLogin.Log.Warn().Err(err).Str("thread_id", thread.ID).Msg("Failed to queue iMessage message")
			}
		}
	}
}

func firstSentMessage(messages []imessage.Message) (*imessage.Message, error) {
	if len(messages) == 0 {
		return nil, errors.New("send succeeded but returned no message ID")
	}
	return &messages[0], nil
}

func messageTimestamp(message imessage.Message) time.Time {
	if message.Timestamp == 0 {
		return time.Now()
	}
	return time.UnixMilli(message.Timestamp)
}

func matrixUnsupported(msg string) error {
	return bridgev2.WrapErrorInStatus(fmt.Errorf("%s", msg)).
		WithErrorAsMessage().
		WithIsCertain(true)
}
