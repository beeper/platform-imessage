package connector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
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

	stopEventLoop chan struct{}
	stopOnce      sync.Once
}

var _ bridgev2.NetworkAPI = (*Client)(nil)
var _ bridgev2.NetworkAPIWithUserID = (*Client)(nil)

func (c *Client) Connect(ctx context.Context) {
	c.UserLogin.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnecting})
	if _, err := c.IM.CurrentUser(); err != nil {
		c.UserLogin.BridgeState.Send(status.BridgeState{
			StateEvent: status.StateBadCredentials,
			Error:      "IMESSAGE_NOT_AVAILABLE",
			Message:    err.Error(),
		})
		return
	}
	c.UserLogin.BridgeState.Send(status.BridgeState{StateEvent: status.StateConnected})

	if err := c.IM.StartEvents(); err != nil {
		c.UserLogin.Log.Warn().Err(err).Msg("Failed to start iMessage event watcher")
		return
	}
	go c.syncExistingChats()
	go c.eventLoop()
}

func (c *Client) Disconnect() {
	c.stopOnce.Do(func() {
		close(c.stopEventLoop)
	})
}

func (c *Client) IsLoggedIn() bool {
	return true
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

func (c *Client) eventLoop() {
	timeout := c.Main.Config.EventPollTimeoutMS
	if timeout <= 0 {
		timeout = 30000
	}

	for {
		select {
		case <-c.stopEventLoop:
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

func (c *Client) syncExistingChats() {
	page, err := c.IM.Chats(nil)
	if err != nil {
		c.UserLogin.Log.Warn().Err(err).Msg("Failed to sync iMessage chats")
		return
	}
	for _, thread := range page.Items {
		thread := thread
		c.reIDKnownSyntheticPortals(context.Background(), thread)
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
