package connector

import (
	"context"
	"strings"

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
	for _, msg := range page.Items {
		if msg.ThreadID == "" {
			msg.ThreadID = threadID
		}
		converted, err := c.convertMessageFromIMessage(ctx, params.Portal, c.Main.Bridge.Bot, msg)
		if err != nil {
			return nil, err
		}
		reactions := make([]*bridgev2.BackfillReaction, 0, len(msg.Reactions))
		for _, reaction := range msg.Reactions {
			reactions = append(reactions, backfillReactionFromIMessage(reaction))
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
		Cursor:   networkid.PaginationCursor(nextBackfillCursor(page, params.Forward)),
		HasMore:  page.HasMore,
		Forward:  params.Forward,
	}, nil
}

func backfillPagination(params bridgev2.FetchMessagesParams) *imessage.Pagination {
	cursor := string(params.Cursor)
	if cursor != "" && !isIMessagePaginationCursor(cursor) {
		if anchorCursor := cursorFromMessage(params.AnchorMessage); isIMessagePaginationCursor(anchorCursor) {
			cursor = anchorCursor
		}
	}
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
	limit := params.Count
	if limit < 0 {
		limit = 0
	}
	return &imessage.Pagination{
		Cursor:    cursor,
		Direction: direction,
		Limit:     limit,
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

func isIMessagePaginationCursor(cursor string) bool {
	cursor = strings.TrimSpace(cursor)
	if cursor == "" {
		return false
	}
	for _, ch := range cursor {
		if ch < '0' || ch > '9' {
			return false
		}
	}
	return true
}

func nextBackfillCursor(page *imessage.Page[imessage.Message], forward bool) string {
	if page == nil {
		return ""
	}
	if forward && page.NewestCursor != "" {
		return page.NewestCursor
	}
	if !forward && page.OldestCursor != "" {
		return page.OldestCursor
	}
	if len(page.Items) == 0 {
		return ""
	}
	if forward {
		return messagePaginationCursor(page.Items[len(page.Items)-1])
	}
	return messagePaginationCursor(page.Items[0])
}

func messagePaginationCursor(msg imessage.Message) string {
	if msg.Cursor != "" {
		return msg.Cursor
	}
	return msg.ID
}
