package connector

import (
	"context"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
)

var _ bridgev2.BackfillingNetworkAPI = (*Client)(nil)

func (c *Client) FetchMessages(ctx context.Context, params bridgev2.FetchMessagesParams) (*bridgev2.FetchMessagesResponse, error) {
	threadID := string(params.Portal.ID)
	pagination := backfillPagination(params)
	page, err := c.IM.Messages(threadID, pagination)
	if err != nil {
		return nil, err
	}

	messages := make([]*bridgev2.BackfillMessage, 0, len(page.Items))
	for i := len(page.Items) - 1; i >= 0; i-- {
		msg := page.Items[i]
		if msg.ThreadID == "" {
			msg.ThreadID = threadID
		}
		converted, err := c.convertMessageFromIMessage(ctx, params.Portal, c.Main.Bridge.Bot, msg)
		if err != nil {
			return nil, err
		}
		reactions := make([]*bridgev2.BackfillReaction, 0, len(msg.Reactions))
		for _, reaction := range msg.Reactions {
			reactions = append(reactions, &bridgev2.BackfillReaction{
				Sender:  bridgev2.EventSender{Sender: imessageid.MakeUserID(reaction.ParticipantID)},
				EmojiID: networkid.EmojiID(reaction.ID),
				Emoji:   reaction.ReactionKey,
			})
		}
		messages = append(messages, &bridgev2.BackfillMessage{
			ConvertedMessage: converted,
			Sender:           c.sender(msg),
			ID:               imessageid.MakeMessageID(msg.ID),
			TxnID:            networkid.TransactionID(msg.ID),
			Timestamp:        messageTimestamp(msg),
			StreamOrder:      msg.Timestamp,
			Reactions:        reactions,
		})
	}

	return &bridgev2.FetchMessagesResponse{
		Messages: messages,
		Cursor:   networkid.PaginationCursor(nextBackfillCursor(page, messages)),
		HasMore:  page.HasMore,
		Forward:  params.Forward,
	}, nil
}

func backfillPagination(params bridgev2.FetchMessagesParams) *imessage.Pagination {
	cursor := string(params.Cursor)
	if cursor == "" {
		cursor = cursorFromMessage(params.AnchorMessage)
	}
	if cursor == "" {
		return nil
	}
	direction := "before"
	if params.Forward {
		direction = "after"
	}
	return &imessage.Pagination{
		Cursor:    cursor,
		Direction: direction,
	}
}

func cursorFromMessage(msg *database.Message) string {
	if msg == nil {
		return ""
	}
	if meta, ok := msg.Metadata.(*imessageid.MessageMetadata); ok && meta.Cursor != "" {
		return meta.Cursor
	}
	return string(msg.ID)
}

func nextBackfillCursor(page *imessage.Page[imessage.Message], messages []*bridgev2.BackfillMessage) string {
	if page == nil {
		return ""
	}
	if page.OldestCursor != "" {
		return page.OldestCursor
	}
	if len(messages) == 0 {
		return ""
	}
	return string(messages[0].ID)
}
