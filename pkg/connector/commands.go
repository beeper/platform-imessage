package connector

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/commands"
	"maunium.net/go/mautrix/bridgev2/simplevent"
)

var cmdCreateIMessageChat = &commands.FullHandler{
	Func: fnCreateIMessageChat,
	Name: "create-imessage-chat",
	Help: commands.HelpMeta{
		Section:     commands.HelpSectionChats,
		Description: "Create an iMessage chat with the required initial message.",
		Args:        "<recipient>... -- <initial message>",
	},
	RequiresLogin: true,
}

func fnCreateIMessageChat(ce *commands.Event) {
	client, ok := clientForCommand(ce, false)
	if !ok {
		return
	}
	recipients, initialMessage := parseCreateChatCommand(ce)
	if len(recipients) == 0 || initialMessage == "" {
		ce.Reply("Usage: `$cmdprefix create-imessage-chat <recipient>... -- <initial message>`")
		return
	}
	thread, _, err := client.IM.CreateChat(recipients, initialMessage, "")
	if err != nil {
		ce.Log.Err(err).Msg("Failed to create iMessage chat")
		ce.Reply("Failed to create iMessage chat: %v", err)
		return
	}

	threadID := ""
	if thread != nil {
		threadID = thread.ID
		client.queueCreatedThread(ce.Ctx, *thread)
		if thread.PartialLastMessage != nil {
			thread.PartialLastMessage.ThreadID = thread.ID
			client.queueCreatedMessage(*thread.PartialLastMessage)
		}
	} else {
		messages, err := client.findRecentlyCreatedMessage("", initialMessage)
		if err != nil {
			ce.Log.Err(err).Msg("Failed to reconcile created iMessage chat")
			ce.Reply("Created iMessage chat, but couldn't reconcile the final thread ID: %v", err)
			return
		}
		if len(messages) > 0 {
			threadID = messages[0].ThreadID
			client.queueCreatedMessage(messages[0])
			client.queueThreadResync(ce.Ctx, threadID)
		}
	}
	if threadID == "" {
		ce.Reply("Created iMessage chat, but the platform didn't return a thread ID.")
		return
	}
	ce.Reply("Created iMessage chat `%s`. The portal should be created momentarily.", threadID)
}

var cmdNotifyAnyway = &commands.FullHandler{
	Func: fnNotifyAnyway,
	Name: "notify-anyway",
	Help: commands.HelpMeta{
		Section:     commands.HelpSectionChats,
		Description: "Press iMessage Notify Anyway for the current portal.",
	},
	RequiresLogin:  true,
	RequiresPortal: true,
}

func fnNotifyAnyway(ce *commands.Event) {
	client, ok := clientForCommand(ce, true)
	if !ok {
		return
	}
	if err := client.IM.NotifyAnyway(string(ce.Portal.ID)); err != nil {
		ce.Log.Err(err).Msg("Failed to notify anyway")
		ce.Reply("Failed to notify anyway: %v", err)
		return
	}
	ce.Reply("Notify Anyway sent.")
}

var cmdSearchMessages = &commands.FullHandler{
	Func: fnSearchMessages,
	Name: "search-messages",
	Help: commands.HelpMeta{
		Section:     commands.HelpSectionChats,
		Description: "Search iMessage messages globally or in the current portal.",
		Args:        "<query>",
	},
	RequiresLogin: true,
}

func fnSearchMessages(ce *commands.Event) {
	query := strings.TrimSpace(ce.RawArgs)
	if query == "" {
		ce.Reply("Usage: `$cmdprefix search-messages <query>`")
		return
	}
	client, ok := clientForCommand(ce, ce.Portal != nil)
	if !ok {
		return
	}
	threadID := ""
	if ce.Portal != nil {
		threadID = string(ce.Portal.ID)
	}
	page, err := client.IM.SearchMessages(query, threadID, nil, 10)
	if err != nil {
		ce.Log.Err(err).Msg("Failed to search iMessage messages")
		ce.Reply("Failed to search iMessage messages: %v", err)
		return
	}
	if len(page.Items) == 0 {
		ce.Reply("No iMessage messages found.")
		return
	}
	ce.Reply(formatSearchResults(page.Items, threadID == ""))
}

func clientForCommand(ce *commands.Event, preferPortal bool) (*Client, bool) {
	var login *bridgev2.UserLogin
	if preferPortal && ce.Portal != nil {
		var err error
		login, _, err = ce.Portal.FindPreferredLogin(ce.Ctx, ce.User, false)
		if errors.Is(err, bridgev2.ErrNotLoggedIn) {
			ce.Reply("You're not logged in in this portal.")
			return nil, false
		} else if err != nil {
			ce.Log.Err(err).Msg("Failed to find preferred login for portal")
			ce.Reply("Failed to find preferred login for portal.")
			return nil, false
		}
	}
	if login == nil {
		login = ce.User.GetDefaultLogin()
	}
	if login == nil {
		ce.Reply("Login not found.")
		return nil, false
	}
	client, ok := login.Client.(*Client)
	if !ok || client == nil {
		ce.Reply("Login is not an iMessage login.")
		return nil, false
	}
	return client, true
}

func parseCreateChatCommand(ce *commands.Event) ([]string, string) {
	raw := strings.TrimSpace(ce.RawArgs)
	if before, after, ok := strings.Cut(raw, " -- "); ok {
		return sortedNonEmptyFields(before), strings.TrimSpace(after)
	}
	for i, arg := range ce.Args {
		if arg == "--message" || arg == "-m" {
			return sortedNonEmptyFields(strings.Join(ce.Args[:i], " ")), strings.TrimSpace(strings.Join(ce.Args[i+1:], " "))
		}
	}
	return nil, ""
}

func sortedNonEmptyFields(input string) []string {
	fields := strings.Fields(input)
	out := fields[:0]
	for _, field := range fields {
		if field != "" {
			out = append(out, field)
		}
	}
	sort.Strings(out)
	return out
}

func (c *Client) queueCreatedThread(ctx context.Context, thread imessage.Thread) {
	c.reIDKnownSyntheticPortals(ctx, thread)
	c.queueThreadReadState(thread)
	c.UserLogin.QueueRemoteEvent(&simplevent.ChatResync{
		EventMeta: c.baseEventMeta(thread.ID).WithType(bridgev2.RemoteEventChatResync),
		ChatInfo:  c.chatInfoFromThread(thread),
	})
}

func (c *Client) queueThreadResync(ctx context.Context, threadID string) {
	if threadID == "" {
		return
	}
	thread, err := c.IM.Chat(threadID)
	if err != nil {
		c.UserLogin.Log.Warn().Err(err).Str("thread_id", threadID).Msg("Failed to load created iMessage chat")
		return
	}
	if thread != nil {
		c.queueCreatedThread(ctx, *thread)
	}
}

func (c *Client) queueCreatedMessage(message imessage.Message) {
	if message.ThreadID == "" {
		return
	}
	c.UserLogin.QueueRemoteEvent(&simplevent.Message[imessage.Message]{
		EventMeta: c.eventMeta(message.ThreadID, message),
		ID:        imessageid.MakeMessageID(message.ID),
		Data:      message,
		ConvertMessageFunc: func(ctx context.Context, portal *bridgev2.Portal, intent bridgev2.MatrixAPI, data imessage.Message) (*bridgev2.ConvertedMessage, error) {
			return c.convertMessageFromIMessage(ctx, portal, intent, data)
		},
	})
}

func formatSearchResults(messages []imessage.Message, includeThread bool) string {
	var builder strings.Builder
	limit := len(messages)
	if limit > 10 {
		limit = 10
	}
	fmt.Fprintf(&builder, "Found %d iMessage message%s:", len(messages), pluralSuffix(len(messages)))
	for i := 0; i < limit; i++ {
		msg := messages[i]
		text := strings.Join(strings.Fields(msg.Text), " ")
		if text == "" && len(msg.Attachments) > 0 {
			text = msg.Attachments[0].FileName
		}
		if text == "" {
			text = "Unsupported iMessage event"
		}
		text = truncate(text, 180)
		if includeThread {
			fmt.Fprintf(&builder, "\n%d. `%s` `%s` %s", i+1, msg.ThreadID, msg.ID, text)
		} else {
			fmt.Fprintf(&builder, "\n%d. `%s` %s", i+1, msg.ID, text)
		}
	}
	return builder.String()
}

func pluralSuffix(count int) string {
	if count == 1 {
		return ""
	}
	return "s"
}

func truncate(input string, maxLen int) string {
	runes := []rune(input)
	if len(runes) <= maxLen {
		return input
	}
	if maxLen <= 3 {
		return string(runes[:maxLen])
	}
	return string(runes[:maxLen-3]) + "..."
}
