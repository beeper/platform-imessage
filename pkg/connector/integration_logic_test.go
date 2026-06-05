package connector

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/commands"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
	"maunium.net/go/mautrix/event"
)

func testClient() *Client {
	return &Client{
		UserLogin: &bridgev2.UserLogin{
			UserLogin: &database.UserLogin{ID: networkid.UserLoginID("self")},
		},
	}
}

func TestParseCreateChatCommand(t *testing.T) {
	recipients, message := parseCreateChatCommand(&commands.Event{
		RawArgs: "+15557654321 +15551234567 -- hello from Matrix",
		Args:    []string{"+15557654321", "+15551234567", "--", "hello", "from", "Matrix"},
	})
	if !reflect.DeepEqual(recipients, []string{"+15551234567", "+15557654321"}) {
		t.Fatalf("unexpected recipients: %#v", recipients)
	}
	if message != "hello from Matrix" {
		t.Fatalf("unexpected initial message: %q", message)
	}

	recipients, message = parseCreateChatCommand(&commands.Event{
		RawArgs: "alice@example.com -m hello again",
		Args:    []string{"alice@example.com", "-m", "hello", "again"},
	})
	if !reflect.DeepEqual(recipients, []string{"alice@example.com"}) {
		t.Fatalf("unexpected -m recipients: %#v", recipients)
	}
	if message != "hello again" {
		t.Fatalf("unexpected -m message: %q", message)
	}
}

func TestSyntheticPortalIDsForThread(t *testing.T) {
	isSelf := true
	dmIDs := syntheticPortalIDsForThread(imessage.Thread{
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "+15551234567"},
			{ID: "me@example.com", IsSelf: &isSelf},
		}},
	})
	if !reflect.DeepEqual(dmIDs, []string{
		"any;-;+15551234567",
		"iMessage;-;+15551234567",
		"SMS;-;+15551234567",
	}) {
		t.Fatalf("unexpected DM synthetic IDs: %#v", dmIDs)
	}

	groupIDs := syntheticPortalIDsForThread(imessage.Thread{
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "b@example.com"},
			{ID: "me@example.com", IsSelf: &isSelf},
			{ID: "a@example.com"},
		}},
	})
	if !reflect.DeepEqual(groupIDs, []string{"group;-;a@example.com,b@example.com"}) {
		t.Fatalf("unexpected group synthetic IDs: %#v", groupIDs)
	}

	groupIDs = syntheticPortalIDsForThread(imessage.Thread{
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "b@example.com"},
			{ID: "me@example.com"},
			{ID: "a@example.com"},
		}},
	}, map[string]bool{"me@example.com": true})
	if !reflect.DeepEqual(groupIDs, []string{"group;-;a@example.com,b@example.com"}) {
		t.Fatalf("unmarked self identifier should not be part of synthetic group ID: %#v", groupIDs)
	}

	groupIDs = syntheticPortalIDsForThread(imessage.Thread{
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "Bob@Example.com"},
			{ID: "Me@Example.com"},
			{ID: "alice@example.com"},
		}},
	}, map[string]bool{"me@example.com": true})
	if !reflect.DeepEqual(groupIDs, []string{"group;-;alice@example.com,bob@example.com"}) {
		t.Fatalf("synthetic group IDs should be canonicalized: %#v", groupIDs)
	}
}

func TestParticipantSetMatchesExistingGroup(t *testing.T) {
	isSelf := true
	thread := imessage.Thread{
		ID:   "any;+;chat123",
		Type: imessage.ThreadTypeGroup,
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "Alice@Example.com"},
			{ID: "+15551234567"},
			{ID: "me@example.com", IsSelf: &isSelf},
		}},
	}
	expected := canonicalParticipantSet([]string{"+15551234567", "alice@example.com"})
	if !participantSetMatchesThread(expected, thread, map[string]bool{"me@example.com": true}) {
		t.Fatal("expected existing group participants to match case-insensitively while ignoring self")
	}

	missing := canonicalParticipantSet([]string{"+15551234567", "bob@example.com"})
	if participantSetMatchesThread(missing, thread, map[string]bool{"me@example.com": true}) {
		t.Fatal("group with different participants must not match")
	}
}

func TestReactionActionMessagesAreNotBridgedAsText(t *testing.T) {
	reactionCreated := imessage.Message{
		ID: "reaction-action",
		Action: &imessage.MessageAction{
			Type: "message_reaction_created",
		},
	}
	if !isReactionActionMessage(reactionCreated) {
		t.Fatal("reaction-created action messages should be suppressed as text")
	}

	reactionDeleted := imessage.Message{
		ID: "reaction-delete-action",
		Action: &imessage.MessageAction{
			Type: "message_reaction_deleted",
		},
	}
	if !isReactionActionMessage(reactionDeleted) {
		t.Fatal("reaction-deleted action messages should be suppressed as text")
	}

	titleChange := imessage.Message{
		ID: "title-action",
		Action: &imessage.MessageAction{
			Type:  "thread_title_updated",
			Title: "New title",
		},
	}
	if isReactionActionMessage(titleChange) {
		t.Fatal("non-reaction action messages must not be suppressed by the reaction filter")
	}
}

func TestIMessageIdentifierValidationAndGhostDM(t *testing.T) {
	conn := &Connector{}
	validIDs := []networkid.UserID{
		networkid.UserID("+15551234567"),
		networkid.UserID("alice@example.com"),
	}
	for _, id := range validIDs {
		if !conn.ValidateUserID(id) {
			t.Fatalf("expected %q to be a valid iMessage user ID", id)
		}
	}
	invalidIDs := []networkid.UserID{
		networkid.UserID(""),
		networkid.UserID("group;-;alice@example.com,bob@example.com"),
		networkid.UserID("alice@example.com,bob@example.com"),
		networkid.UserID("alice\n@example.com"),
	}
	for _, id := range invalidIDs {
		if conn.ValidateUserID(id) {
			t.Fatalf("expected %q to be rejected as an iMessage user ID", id)
		}
	}

	client := testClient()
	resp, err := client.CreateChatWithGhost(t.Context(), &bridgev2.Ghost{Ghost: &database.Ghost{ID: networkid.UserID("alice@example.com")}})
	if err != nil {
		t.Fatal(err)
	}
	if resp == nil || resp.PortalKey.ID != "any;-;alice@example.com" {
		t.Fatalf("unexpected ghost DM response: %#v", resp)
	}

	resolved, err := client.ResolveIdentifier(t.Context(), "alice@example.com", true)
	if err != nil {
		t.Fatal(err)
	}
	if resolved == nil || resolved.UserID != "alice@example.com" || resolved.Chat == nil || resolved.Chat.PortalKey.ID != "any;-;alice@example.com" {
		t.Fatalf("unexpected email resolve response: %#v", resolved)
	}
}

func TestConvertedMessagePartIDsAreStable(t *testing.T) {
	parts := []*bridgev2.ConvertedMessagePart{
		{Content: &event.MessageEventContent{Body: "text"}},
		{Content: &event.MessageEventContent{Body: "image.jpg"}},
		{Content: &event.MessageEventContent{Body: "file.pdf"}},
	}
	setConvertedMessagePartIDs(parts)
	if parts[0].ID != "" || parts[1].ID != "1" || parts[2].ID != "2" {
		t.Fatalf("unexpected part IDs: %q %q %q", parts[0].ID, parts[1].ID, parts[2].ID)
	}
}

func TestFileInfoForAttachmentIncludesImageDimensions(t *testing.T) {
	const png1x2Base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAACCAYAAACZgbYnAAAADUlEQVR4nGNgYGD4DwABBAEAghnFoQAAAABJRU5ErkJggg=="
	data, err := base64.StdEncoding.DecodeString(png1x2Base64)
	if err != nil {
		t.Fatal(err)
	}

	info := fileInfoForAttachment(data, imessage.Attachment{}, "image/png")
	if info.Size != len(data) {
		t.Fatalf("unexpected file size: %d", info.Size)
	}
	if info.Width != 1 || info.Height != 2 {
		t.Fatalf("expected image dimensions in Matrix file info, got %dx%d", info.Width, info.Height)
	}
}

func TestFileInfoForAttachmentSkipsDimensionsForGenericFiles(t *testing.T) {
	info := fileInfoForAttachment([]byte("plain text"), imessage.Attachment{}, "text/plain")
	if info.Width != 0 || info.Height != 0 {
		t.Fatalf("did not expect generic file dimensions, got %dx%d", info.Width, info.Height)
	}
}

func TestResponseThreadIDPrefersRealThread(t *testing.T) {
	if got := responseThreadID("group;-;a,b", imessage.Message{ThreadID: "iMessage;-;real-chat"}); got != "iMessage;-;real-chat" {
		t.Fatalf("expected real thread ID, got %q", got)
	}
	if got := responseThreadID("group;-;a,b", imessage.Message{}); got != "group;-;a,b" {
		t.Fatalf("expected portal fallback, got %q", got)
	}
}

func TestRecipientsFromThreadIDOnlyAcceptsSyntheticCreationPortals(t *testing.T) {
	if got := recipientsFromThreadID("any;-;alice@example.com"); !reflect.DeepEqual(got, []string{"alice@example.com"}) {
		t.Fatalf("unexpected any recipients: %#v", got)
	}
	if got := recipientsFromThreadID("group;-;alice@example.com,bob@example.com"); !reflect.DeepEqual(got, []string{"alice@example.com", "bob@example.com"}) {
		t.Fatalf("unexpected group recipients: %#v", got)
	}
	if got := recipientsFromThreadID("iMessage;-;alice@example.com"); got != nil {
		t.Fatalf("real iMessage portal must not be treated as synthetic creation portal: %#v", got)
	}
	if got := recipientsFromThreadID("SMS;-;+15551234567"); got != nil {
		t.Fatalf("real SMS portal must not be treated as synthetic creation portal: %#v", got)
	}
}

func TestChatInfoFromThreadIncludesMembersAndAvatar(t *testing.T) {
	client := testClient()
	self := true
	thread := imessage.Thread{
		ID:     "iMessage;-;chat",
		Title:  "Project",
		Type:   imessage.ThreadTypeGroup,
		ImgURL: "asset://account/group-avatar/1.heic",
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "alice@example.com", FullName: "Alice", ImgURL: "asset://account/alice/1.heic"},
			{ID: "bob@example.com", FullName: "Bob"},
			{ID: "self@example.com", IsSelf: &self},
		}},
	}

	info := client.chatInfoFromThread(thread)
	if info.Name == nil || *info.Name != "Project" {
		t.Fatalf("unexpected room name: %#v", info.Name)
	}
	if info.Type == nil || *info.Type != database.RoomTypeDefault {
		t.Fatalf("unexpected room type: %#v", info.Type)
	}
	if info.Avatar == nil || info.Avatar.ID != networkid.AvatarID(thread.ImgURL) {
		t.Fatalf("unexpected room avatar: %#v", info.Avatar)
	}
	if !info.CanBackfill {
		t.Fatal("real iMessage thread should advertise bridgev2 backfill support")
	}
	if info.Members == nil || !info.Members.IsFull || info.Members.TotalMemberCount != 3 {
		t.Fatalf("unexpected member list metadata: %#v", info.Members)
	}
	alice := info.Members.MemberMap[imessageid.MakeUserID("alice@example.com")]
	if alice.UserInfo == nil || alice.UserInfo.Name == nil || *alice.UserInfo.Name != "Alice" {
		t.Fatalf("unexpected Alice info: %#v", alice.UserInfo)
	}
	if alice.UserInfo.Avatar == nil || alice.UserInfo.Avatar.ID != "asset://account/alice/1.heic" {
		t.Fatalf("unexpected Alice avatar: %#v", alice.UserInfo.Avatar)
	}
	if _, ok := info.Members.MemberMap[imessageid.MakeUserID("self@example.com")]; ok {
		t.Fatal("self participant should not be added as a remote ghost")
	}
}

func TestParticipantsForChatInfoSkipsUnmarkedSelfIdentifier(t *testing.T) {
	thread := imessage.Thread{
		ID:   "any;+;group",
		Type: imessage.ThreadTypeGroup,
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "alice@example.com"},
			{ID: "me@example.com"},
			{ID: "bob@example.com"},
		}},
	}

	participants := participantsForChatInfo(thread, database.RoomTypeDefault, map[string]bool{"me@example.com": true})
	if len(participants) != 2 || participants[0].ID != "alice@example.com" || participants[1].ID != "bob@example.com" {
		t.Fatalf("unmarked self identifier should be excluded from chat info participants: %#v", participants)
	}
}

func TestChatInfoFromThreadTreatsGroupThreadIDAsGroupEvenIfTypeIsSingle(t *testing.T) {
	client := testClient()
	self := true
	thread := imessage.Thread{
		ID:   "any;+;untitled-group",
		Type: imessage.ThreadTypeSingle,
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "alice@example.com"},
			{ID: "bob@example.com"},
			{ID: "self@example.com", IsSelf: &self},
		}},
	}

	info := client.chatInfoFromThread(thread)
	if info.Type == nil || *info.Type != database.RoomTypeDefault {
		t.Fatalf("multi-remote iMessage thread should be a group, got %#v", info.Type)
	}
	if info.Members == nil || info.Members.TotalMemberCount != 3 {
		t.Fatalf("expected two remote members plus bridge user, got %#v", info.Members)
	}
}

func TestChatInfoFromThreadKeepsMultiHandleSingleAsDM(t *testing.T) {
	client := testClient()
	thread := imessage.Thread{
		ID:   "any;-;alice@example.com",
		Type: imessage.ThreadTypeSingle,
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "alice@example.com"},
			{ID: "+15551234567"},
		}},
	}

	info := client.chatInfoFromThread(thread)
	if info.Type == nil || *info.Type != database.RoomTypeDM {
		t.Fatalf("multi-handle single-recipient thread should stay a DM, got %#v", info.Type)
	}
	if info.Members == nil || info.Members.TotalMemberCount != 2 {
		t.Fatalf("expected one remote member plus bridge user, got %#v", info.Members)
	}
	if _, ok := info.Members.MemberMap[imessageid.MakeUserID("+15551234567")]; ok {
		t.Fatal("alternate DM handle should not be exposed as a second remote member")
	}
}

func TestSyntheticChatResponseDoesNotAdvertiseBackfill(t *testing.T) {
	client := testClient()
	resp := client.syntheticChatResponse([]string{"alice@example.com"}, "")
	if resp.PortalInfo == nil {
		t.Fatal("expected portal info")
	}
	if resp.PortalInfo.CanBackfill {
		t.Fatal("synthetic pre-send portal should not advertise backfill until reconciled to a real thread")
	}
}

func TestThreadLatestMessageTimestamp(t *testing.T) {
	thread := imessage.Thread{
		Timestamp: 1700000000000,
		PartialLastMessage: &imessage.Message{
			Timestamp: 1700000001234,
		},
	}
	if got, want := threadLatestMessageTimestamp(thread), time.UnixMilli(1700000001234); !got.Equal(want) {
		t.Fatalf("expected partial last message timestamp %s, got %s", want, got)
	}

	thread.PartialLastMessage = nil
	if got, want := threadLatestMessageTimestamp(thread), time.UnixMilli(1700000000000); !got.Equal(want) {
		t.Fatalf("expected thread timestamp %s, got %s", want, got)
	}

	if got := threadLatestMessageTimestamp(imessage.Thread{}); !got.IsZero() {
		t.Fatalf("expected zero timestamp for empty thread, got %s", got)
	}
}

func TestChatInfoChangeFromAction(t *testing.T) {
	client := testClient()

	titleChange := client.chatInfoChangeFromAction(imessage.MessageAction{
		Type:  "thread_title_updated",
		Title: "New title",
	})
	if titleChange == nil || titleChange.ChatInfo == nil || titleChange.ChatInfo.Name == nil || *titleChange.ChatInfo.Name != "New title" {
		t.Fatalf("unexpected title change: %#v", titleChange)
	}

	addChange := client.chatInfoChangeFromAction(imessage.MessageAction{
		Type:               "thread_participants_added",
		ActorParticipantID: "admin@example.com",
		ParticipantIDs:     []string{"new@example.com"},
		Participants:       []imessage.User{{ID: "new@example.com", FullName: "New User"}},
	})
	added := addChange.MemberChanges.MemberMap[imessageid.MakeUserID("new@example.com")]
	if added.Membership != event.MembershipJoin || added.PrevMembership != event.MembershipLeave {
		t.Fatalf("unexpected add membership: %#v", added)
	}
	if added.UserInfo == nil || added.UserInfo.Name == nil || *added.UserInfo.Name != "New User" {
		t.Fatalf("unexpected added user info: %#v", added.UserInfo)
	}

	removeChange := client.chatInfoChangeFromAction(imessage.MessageAction{
		Type:           "thread_participants_removed",
		ParticipantIDs: []string{"old@example.com"},
	})
	removed := removeChange.MemberChanges.MemberMap[imessageid.MakeUserID("old@example.com")]
	if removed.Membership != event.MembershipLeave || removed.PrevMembership != event.MembershipJoin {
		t.Fatalf("unexpected remove membership: %#v", removed)
	}
}

func TestBackfillPagination(t *testing.T) {
	cursorPage := backfillPagination(bridgev2.FetchMessagesParams{
		Cursor:  networkid.PaginationCursor("cursor-1"),
		Forward: true,
		Count:   37,
	})
	if cursorPage == nil || cursorPage.Cursor != "cursor-1" || cursorPage.Direction != "after" || cursorPage.Limit != 37 {
		t.Fatalf("unexpected cursor pagination: %#v", cursorPage)
	}

	anchorPage := backfillPagination(bridgev2.FetchMessagesParams{
		AnchorMessage: &database.Message{
			ID:       networkid.MessageID("message-id"),
			Metadata: &imessageid.MessageMetadata{Cursor: "message-cursor"},
		},
	})
	if anchorPage == nil || anchorPage.Cursor != "message-cursor" || anchorPage.Direction != "before" {
		t.Fatalf("unexpected anchor pagination: %#v", anchorPage)
	}

	fallbackPage := backfillPagination(bridgev2.FetchMessagesParams{
		AnchorMessage: &database.Message{ID: networkid.MessageID("message-id")},
	})
	if fallbackPage == nil || fallbackPage.Cursor != "message-id" || fallbackPage.Direction != "before" {
		t.Fatalf("unexpected fallback pagination: %#v", fallbackPage)
	}

	repairedPage := backfillPagination(bridgev2.FetchMessagesParams{
		Cursor: networkid.PaginationCursor("02F90C51-B1F7-4C30-8F5D-55CB535130F6"),
		AnchorMessage: &database.Message{
			ID:       networkid.MessageID("message-id"),
			Metadata: &imessageid.MessageMetadata{Cursor: "1696075189006000000"},
		},
	})
	if repairedPage == nil || repairedPage.Cursor != "1696075189006000000" {
		t.Fatalf("unexpected repaired pagination cursor: %#v", repairedPage)
	}
	if !isIMessagePaginationCursor("1696075189006000000") || isIMessagePaginationCursor("message-id") {
		t.Fatal("iMessage pagination cursor validation should only accept numeric cursors")
	}

	page := &imessage.Page[imessage.Message]{
		OldestCursor: "oldest",
		NewestCursor: "newest",
	}
	if got := nextBackfillCursor(page, false); got != "oldest" {
		t.Fatalf("backward backfill should use oldest cursor, got %q", got)
	}
	if got := nextBackfillCursor(page, true); got != "newest" {
		t.Fatalf("forward backfill should use newest cursor, got %q", got)
	}

	imessagePage := &imessage.Page[imessage.Message]{
		Items: []imessage.Message{
			{ID: "old-id", Cursor: "old-cursor"},
			{ID: "new-id", Cursor: "new-cursor"},
		},
	}
	if got := nextBackfillCursor(imessagePage, false); got != "old-cursor" {
		t.Fatalf("backward cursor fallback should use oldest returned message cursor, got %q", got)
	}
	if got := nextBackfillCursor(imessagePage, true); got != "new-cursor" {
		t.Fatalf("forward cursor fallback should use newest returned message cursor, got %q", got)
	}

	idOnlyPage := &imessage.Page[imessage.Message]{
		Items: []imessage.Message{{ID: "old-id"}, {ID: "new-id"}},
	}
	if got := nextBackfillCursor(idOnlyPage, false); got != "old-id" {
		t.Fatalf("messages without platform cursors should fall back to IDs, got %q", got)
	}
}

func TestIMessageReactionMetadataAndDeleteSender(t *testing.T) {
	senderID, reactionKey := splitStandardIMessageReactionID("alice@example.comlike")
	if senderID != "alice@example.com" || reactionKey != "like" {
		t.Fatalf("unexpected like reaction split: %q %q", senderID, reactionKey)
	}

	senderID, reactionKey = splitStandardIMessageReactionID("+15551234567emphasize")
	if senderID != "+15551234567" || reactionKey != "emphasize" {
		t.Fatalf("unexpected emphasize reaction split: %q %q", senderID, reactionKey)
	}

	senderID, reactionKey = splitStandardIMessageReactionID("alice@example.comcustom")
	if senderID != "" || reactionKey != "" {
		t.Fatalf("unexpected custom reaction split without DB metadata: %q %q", senderID, reactionKey)
	}

	client := testClient()
	senderID, reactionKey = client.reactionSenderAndKey(t.Context(), networkid.MessageID("message-id"), "bob@example.comheart")
	if senderID != "bob@example.com" || reactionKey != "❤️" {
		t.Fatalf("unexpected fallback reaction sender/key: %q %q", senderID, reactionKey)
	}

	backfillReaction := backfillReactionFromIMessage(imessage.Reaction{
		ID:            "alice@example.comlike",
		ReactionKey:   "like",
		ParticipantID: "alice@example.com",
	})
	if backfillReaction.Sender.Sender != "alice@example.com" || backfillReaction.EmojiID != "alice@example.comlike" || backfillReaction.Emoji != "👍" {
		t.Fatalf("unexpected backfill reaction: %#v", backfillReaction)
	}
	meta, ok := backfillReaction.DBMetadata.(*imessageid.ReactionMetadata)
	if !ok || meta.ReactionID != "alice@example.comlike" || meta.ReactionKey != "like" {
		t.Fatalf("unexpected backfill reaction metadata: %#v", backfillReaction.DBMetadata)
	}
}

func TestIMessageReactionKeyMapping(t *testing.T) {
	for bridgeKey, platformKey := range map[string]string{
		"❤️":   "heart",
		"❤":    "heart",
		"👍":    "like",
		"👍️":   "like",
		"👎":    "dislike",
		"👎️":   "dislike",
		"HAHA": "laugh",
		"‼️":   "emphasize",
		"‼":    "emphasize",
		"❓":    "question",
		"❓️":   "question",
	} {
		got, ok := platformReactionKeyFromBridge(bridgeKey)
		if !ok || got != platformKey {
			t.Fatalf("expected %q to map to %q, got %q ok=%v", bridgeKey, platformKey, got, ok)
		}
	}

	for platformKey, bridgeKey := range platformReactionToBridgeReaction {
		if got := bridgeReactionKeyFromPlatform(platformKey); got != bridgeKey {
			t.Fatalf("expected %q to map back to %q, got %q", platformKey, bridgeKey, got)
		}
	}

	if _, ok := platformReactionKeyFromBridge("😂"); ok {
		t.Fatal("custom reactions must not be sent to platform-imessage when capabilities advertise fixed tapbacks only")
	}
}

func TestMatrixReactionKeyReadsParsedAndRawContent(t *testing.T) {
	parsed := matrixReactionKey(&bridgev2.MatrixReaction{
		MatrixEventBase: bridgev2.MatrixEventBase[*event.ReactionEventContent]{
			Content: &event.ReactionEventContent{RelatesTo: event.RelatesTo{Key: "👍"}},
		},
	})
	if parsed != "👍" {
		t.Fatalf("expected parsed reaction key, got %q", parsed)
	}

	variant := matrixReactionKey(&bridgev2.MatrixReaction{
		MatrixEventBase: bridgev2.MatrixEventBase[*event.ReactionEventContent]{
			Content: &event.ReactionEventContent{RelatesTo: event.RelatesTo{Key: "👍️"}},
		},
	})
	if variant != "👍" {
		t.Fatalf("expected variation selector reaction key to normalize, got %q", variant)
	}

	raw := matrixReactionKey(&bridgev2.MatrixReaction{
		MatrixEventBase: bridgev2.MatrixEventBase[*event.ReactionEventContent]{
			Event: &event.Event{Content: event.Content{VeryRaw: []byte(`{"m.relates_to":{"key":"HAHA"}}`)}},
		},
	})
	if raw != "HAHA" {
		t.Fatalf("expected raw reaction key, got %q", raw)
	}
}

func TestReactionKeyFromDBReaction(t *testing.T) {
	if got := reactionKeyFromDBReaction(&database.Reaction{
		Emoji: "👍",
		Metadata: &imessageid.ReactionMetadata{
			ReactionKey: "like",
		},
	}); got != "like" {
		t.Fatalf("expected metadata reaction key, got %q", got)
	}

	if got := reactionKeyFromDBReaction(&database.Reaction{Emoji: "👍"}); got != "like" {
		t.Fatalf("expected visible reaction fallback to become platform key, got %q", got)
	}

	if got := reactionKeyFromDBReaction(&database.Reaction{EmojiID: networkid.EmojiID("alice@example.comheart")}); got != "heart" {
		t.Fatalf("expected standard reaction ID fallback, got %q", got)
	}
}

func TestShouldRemoveSupersededReaction(t *testing.T) {
	old := &database.Reaction{
		MessageID:     networkid.MessageID("message-guid"),
		MessagePartID: networkid.PartID("1"),
		SenderID:      networkid.UserID("self"),
		EmojiID:       networkid.EmojiID("selflike"),
	}
	if !shouldRemoveSupersededReaction(old, nil, networkid.EmojiID("selfheart")) {
		t.Fatal("expected old reaction to be removed when adding a different reaction")
	}
	if shouldRemoveSupersededReaction(old, nil, networkid.EmojiID("selflike")) {
		t.Fatal("new reaction should not remove itself")
	}
	if shouldRemoveSupersededReaction(old, []*database.Reaction{{
		MessageID:     old.MessageID,
		MessagePartID: old.MessagePartID,
		SenderID:      old.SenderID,
		EmojiID:       old.EmojiID,
	}}, networkid.EmojiID("selfheart")) {
		t.Fatal("kept reactions must not be removed")
	}
}

func TestPlatformMessageIDPreservesBridgeV2PartID(t *testing.T) {
	msg := &database.Message{
		ID:     networkid.MessageID("message-guid"),
		PartID: networkid.PartID("2"),
	}
	if got := platformMessageID(msg); got != "message-guid_2" {
		t.Fatalf("expected platform part message ID, got %q", got)
	}

	msg.PartID = ""
	if got := platformMessageID(msg); got != "message-guid" {
		t.Fatalf("expected first-part message ID, got %q", got)
	}

	reaction := &database.Reaction{
		MessageID:     networkid.MessageID("message-guid"),
		MessagePartID: networkid.PartID("3"),
	}
	if got := platformReactionMessageID(reaction); got != "message-guid_3" {
		t.Fatalf("expected platform reaction target ID, got %q", got)
	}

	if got := platformMessageIDParts(networkid.MessageID("message-guid_1"), networkid.PartID("2")); got != "message-guid_1" {
		t.Fatalf("must not double-encode platform message part IDs, got %q", got)
	}
}

func TestEditFromUpdatedMessageUpdatesAllParts(t *testing.T) {
	existing := []*database.Message{
		{ID: networkid.MessageID("message-id"), PartID: networkid.PartID("0")},
		{ID: networkid.MessageID("message-id"), PartID: networkid.PartID("1")},
	}
	converted := &bridgev2.ConvertedMessage{
		Parts: []*bridgev2.ConvertedMessagePart{
			{
				Type: event.EventMessage,
				Content: &event.MessageEventContent{
					MsgType: event.MsgText,
					Body:    "updated text",
				},
			},
			{
				Type: event.EventMessage,
				Content: &event.MessageEventContent{
					MsgType: event.MsgImage,
					Body:    "loaded.jpg",
				},
			},
			{
				Type: event.EventMessage,
				Content: &event.MessageEventContent{
					MsgType: event.MsgFile,
					Body:    "added.pdf",
				},
			},
		},
	}

	edit, err := editFromUpdatedMessage(existing, converted)
	if err != nil {
		t.Fatal(err)
	}
	if len(edit.ModifiedParts) != 2 {
		t.Fatalf("expected existing parts to be modified, got %d", len(edit.ModifiedParts))
	}
	if edit.ModifiedParts[0].Part != existing[0] || edit.ModifiedParts[0].Content.Body != "updated text" {
		t.Fatalf("unexpected first modified part: %#v", edit.ModifiedParts[0])
	}
	if edit.ModifiedParts[1].Part != existing[1] || edit.ModifiedParts[1].Content.MsgType != event.MsgImage {
		t.Fatalf("unexpected second modified part: %#v", edit.ModifiedParts[1])
	}
	if edit.AddedParts == nil || len(edit.AddedParts.Parts) != 1 || edit.AddedParts.Parts[0].Content.Body != "added.pdf" {
		t.Fatalf("expected extra converted part to be added, got %#v", edit.AddedParts)
	}
	if len(edit.DeletedParts) != 0 {
		t.Fatalf("did not expect deleted parts: %#v", edit.DeletedParts)
	}
}

func TestEditFromUpdatedMessageDeletesSurplusParts(t *testing.T) {
	existing := []*database.Message{
		{ID: networkid.MessageID("message-id"), PartID: networkid.PartID("0")},
		{ID: networkid.MessageID("message-id"), PartID: networkid.PartID("1")},
	}
	converted := &bridgev2.ConvertedMessage{
		Parts: []*bridgev2.ConvertedMessagePart{{
			Type: event.EventMessage,
			Content: &event.MessageEventContent{
				MsgType: event.MsgText,
				Body:    "only remaining part",
			},
		}},
	}

	edit, err := editFromUpdatedMessage(existing, converted)
	if err != nil {
		t.Fatal(err)
	}
	if len(edit.ModifiedParts) != 1 || edit.ModifiedParts[0].Part != existing[0] {
		t.Fatalf("unexpected modified parts: %#v", edit.ModifiedParts)
	}
	if len(edit.DeletedParts) != 1 || edit.DeletedParts[0] != existing[1] {
		t.Fatalf("expected surplus part to be deleted, got %#v", edit.DeletedParts)
	}
	if edit.AddedParts != nil {
		t.Fatalf("did not expect added parts: %#v", edit.AddedParts)
	}
}

func TestCapabilitiesAdvertiseSyntheticGroupCreation(t *testing.T) {
	conn := &Connector{}
	general := conn.GetCapabilities()
	if general.ImplicitReadReceipts {
		t.Fatal("implicit read receipts should stay disabled because mark-read uses Messages.app automation")
	}
	if !general.Provisioning.ResolveIdentifier.CreateDM {
		t.Fatal("expected CreateDM to be advertised")
	}
	if !general.Provisioning.ResolveIdentifier.LookupEmail || !general.Provisioning.ResolveIdentifier.AnyPhone {
		t.Fatalf("expected email lookup and any-phone capabilities for iMessage identifiers: %#v", general.Provisioning.ResolveIdentifier)
	}
	if !general.Provisioning.ResolveIdentifier.ContactList || !general.Provisioning.ResolveIdentifier.Search {
		t.Fatalf("expected contact list and search capabilities: %#v", general.Provisioning.ResolveIdentifier)
	}
	groupCaps, ok := general.Provisioning.GroupCreation["group"]
	if !ok {
		t.Fatalf("expected iMessage synthetic group creation to be advertised: %#v", general.Provisioning.GroupCreation)
	}
	if !groupCaps.Participants.Allowed || !groupCaps.Participants.Required || groupCaps.Participants.MinLength != 2 {
		t.Fatalf("unexpected iMessage group participant capability: %#v", groupCaps.Participants)
	}
	if !groupCaps.Name.Allowed {
		t.Fatalf("expected iMessage group names to be allowed: %#v", groupCaps.Name)
	}

	client := testClient()
	first := client.GetCapabilities(t.Context(), nil)
	second := client.GetCapabilities(t.Context(), nil)
	first.DeleteChat = false
	if !second.DeleteChat {
		t.Fatal("room capabilities must be cloned per call")
	}
	if first.Formatting[event.FmtBold] != event.CapLevelDropped {
		t.Fatalf("formatting should be declared dropped, got %v", first.Formatting[event.FmtBold])
	}
	if !reflect.DeepEqual(first.AllowedReactions, supportedIMessageReactions) || first.CustomEmojiReactions {
		t.Fatalf("unexpected reaction capability declaration: allowed=%#v custom=%v", first.AllowedReactions, first.CustomEmojiReactions)
	}
	if first.File[event.MsgImage].MimeTypes["image/jpeg"] != event.CapLevelFullySupported ||
		first.File[event.MsgImage].MimeTypes["*/*"] != event.CapabilitySupportLevel(0) {
		t.Fatalf("image capability should match platform-imessage supported MIME types: %#v", first.File[event.MsgImage].MimeTypes)
	}
	if first.File[event.MsgFile].MimeTypes["*/*"] != event.CapLevelFullySupported {
		t.Fatalf("generic file capability should allow all MIME types: %#v", first.File[event.MsgFile].MimeTypes)
	}
	if !first.ReadReceipts {
		t.Fatal("explicit read receipts should remain advertised")
	}

	syntheticPortal := &bridgev2.Portal{Portal: &database.Portal{PortalKey: networkid.PortalKey{ID: "group;-;alice@example.com,bob@example.com"}}}
	syntheticCaps := client.GetCapabilities(t.Context(), syntheticPortal)
	if syntheticCaps.File != nil {
		t.Fatalf("synthetic new-chat portals must not advertise file sending before initial text reconciliation: %#v", syntheticCaps.File)
	}
	existingPortal := &bridgev2.Portal{Portal: &database.Portal{PortalKey: networkid.PortalKey{ID: "iMessage;-;real-chat"}}}
	existingCaps := client.GetCapabilities(t.Context(), existingPortal)
	if existingCaps.File == nil {
		t.Fatal("existing iMessage portals should advertise file sending")
	}
}

func TestCreateGroupReturnsSyntheticPortal(t *testing.T) {
	client := testClient()
	resp, err := client.CreateGroup(t.Context(), &bridgev2.GroupCreateParams{
		Participants: []networkid.UserID{"bob@example.com", "alice@example.com"},
		Name:         &event.RoomNameEventContent{Name: "Project"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if resp == nil || resp.PortalKey.ID != "group;-;alice@example.com,bob@example.com" {
		t.Fatalf("unexpected group create response: %#v", resp)
	}
	if resp.PortalInfo == nil || resp.PortalInfo.Name == nil || *resp.PortalInfo.Name != "Project" {
		t.Fatalf("expected group name in portal info: %#v", resp.PortalInfo)
	}
	if resp.PortalInfo.Type == nil || *resp.PortalInfo.Type != database.RoomTypeDefault {
		t.Fatalf("expected group room type, got %#v", resp.PortalInfo.Type)
	}
	if resp.PortalInfo.Members == nil || !resp.PortalInfo.Members.IsFull || resp.PortalInfo.Members.TotalMemberCount != 3 {
		t.Fatalf("expected two remote members plus bridge user in synthetic group: %#v", resp.PortalInfo.Members)
	}
	self := resp.PortalInfo.Members.MemberMap[client.GetUserID()]
	if !self.IsFromMe || self.SenderLogin != client.UserLogin.ID || self.Membership != event.MembershipJoin {
		t.Fatalf("expected synthetic group to include bridge user membership: %#v", self)
	}
}

func TestSyntheticDMIncludesBridgeUser(t *testing.T) {
	client := testClient()
	resp := client.syntheticChatResponse([]string{"alice@example.com"}, "")
	if resp == nil || resp.PortalInfo == nil || resp.PortalInfo.Members == nil {
		t.Fatalf("unexpected synthetic DM response: %#v", resp)
	}
	if resp.PortalInfo.Members.TotalMemberCount != 2 {
		t.Fatalf("expected remote member plus bridge user in synthetic DM: %#v", resp.PortalInfo.Members)
	}
	self := resp.PortalInfo.Members.MemberMap[client.GetUserID()]
	if !self.IsFromMe || self.SenderLogin != client.UserLogin.ID || self.Membership != event.MembershipJoin {
		t.Fatalf("expected synthetic DM to include bridge user membership: %#v", self)
	}
}

func TestPermissionInstructions(t *testing.T) {
	instructions := permissionInstructions(&imessage.AuthorizationStatus{
		Permissions: []imessage.PermissionStatus{{
			Title:      "Accessibility",
			Authorized: true,
			Required:   true,
			Detail:     "The bridge can control Messages.app.",
		}, {
			Title:    "Messages Data",
			Required: true,
			Detail:   "Allow access to ~/Library/Messages.",
		}, {
			Title:  "Automation",
			Detail: "Optional prompt.",
		}},
	})
	if !strings.Contains(instructions, "[ok] Accessibility - The bridge can control Messages.app.") {
		t.Fatalf("missing authorized permission line:\n%s", instructions)
	}
	if !strings.Contains(instructions, "[ ] Messages Data - Allow access to ~/Library/Messages.") {
		t.Fatalf("missing missing-permission line:\n%s", instructions)
	}
	if strings.Contains(instructions, "Automation") {
		t.Fatalf("optional permission should not be shown as blocking:\n%s", instructions)
	}
}

func TestMissingPermissionMessage(t *testing.T) {
	message := missingPermissionMessage(&imessage.AuthorizationStatus{
		Permissions: []imessage.PermissionStatus{{
			Title:    "Accessibility",
			Required: true,
		}, {
			Title:      "Contacts",
			Required:   true,
			Authorized: true,
		}, {
			Title: "Automation",
		}},
	})
	if message != "Missing local iMessage permissions: Accessibility" {
		t.Fatalf("unexpected missing permission message: %q", message)
	}
}

func TestAuthorizationStatusDecodesAutomationHealth(t *testing.T) {
	var authStatus imessage.AuthorizationStatus
	if err := json.Unmarshal([]byte(`{
		"authorized": true,
		"automation": {
			"status": "unavailable",
			"available": false,
			"reason": "LOGINWINDOW_FRONTMOST",
			"message": "Unlock the desktop session.",
			"frontmostBundleID": "com.apple.loginwindow",
			"frontmostName": "loginwindow",
			"messagesRunning": true,
			"messagesActive": false,
			"messagesHidden": false,
			"messagesWindowCount": 1
		}
	}`), &authStatus); err != nil {
		t.Fatal(err)
	}
	if authStatus.Automation.Available || authStatus.Automation.Reason != "LOGINWINDOW_FRONTMOST" || authStatus.Automation.FrontmostBundleID != "com.apple.loginwindow" {
		t.Fatalf("unexpected automation status: %#v", authStatus.Automation)
	}
}

func TestBridgeStateForUnavailableAutomation(t *testing.T) {
	state := bridgeStateForAutomationStatus(imessage.AutomationStatus{
		Status:              "unavailable",
		Available:           false,
		Reason:              "LOGINWINDOW_FRONTMOST",
		Message:             "Unlock the desktop session.",
		FrontmostBundleID:   "com.apple.loginwindow",
		FrontmostName:       "loginwindow",
		MessagesRunning:     true,
		MessagesWindowCount: 1,
	})
	if state == nil {
		t.Fatal("expected transient bridge state for unavailable automation")
	}
	if state.StateEvent != status.StateConnected || state.Error != "IMESSAGE_AUTOMATION_UNAVAILABLE" {
		t.Fatalf("unexpected bridge state: %#v", state)
	}
	if state.Reason != "LOGINWINDOW_FRONTMOST" || state.Info["frontmost_bundle_id"] != "com.apple.loginwindow" {
		t.Fatalf("missing automation details: %#v", state.Info)
	}

	if available := bridgeStateForAutomationStatus(imessage.AutomationStatus{Status: "available", Available: true}); available != nil {
		t.Fatalf("available automation should not produce bridge state: %#v", available)
	}
}

func TestSkipPermissionValidationDefaultsOn(t *testing.T) {
	var config Config
	if !config.ShouldSkipPermissionValidation() {
		t.Fatal("omitted skip_permission_validation should default to true")
	}

	explicitFalse := false
	config.SkipPermissionValidation = &explicitFalse
	if config.ShouldSkipPermissionValidation() {
		t.Fatal("explicit false skip_permission_validation should be honored")
	}
}

func TestSendPermissionCheckHonorsSkipValidationDefault(t *testing.T) {
	client := &Client{Main: &Connector{}}
	if err := client.ensureAccessibilityForSending(); err != nil {
		t.Fatalf("default skip_permission_validation should skip send-time permission prompts: %v", err)
	}
}

func TestSyntheticTextMessagesUseCreateChat(t *testing.T) {
	if !shouldCreateChatForOutgoingText("any;-;cigdem.cabuker@icloud.com", "") {
		t.Fatal("new synthetic DM text should use CreateChat instead of SendText")
	}
	if !shouldCreateChatForOutgoingText("group;-;alice@example.com,bob@example.com", "") {
		t.Fatal("new synthetic group text should use CreateChat instead of SendText")
	}
	if shouldCreateChatForOutgoingText("any;-;cigdem.cabuker@icloud.com", "reply-id") {
		t.Fatal("replies should not use CreateChat")
	}
	if shouldCreateChatForOutgoingText("iMessage;-;real-chat", "") {
		t.Fatal("real iMessage thread IDs should use SendText")
	}
}

func TestCreateChatIgnoresStalePartialLastMessage(t *testing.T) {
	isSender := true
	if sentPartialLastMessageMatches(&imessage.Message{Text: "old", IsSender: &isSender}, "new") {
		t.Fatal("stale partial last message must not be used as the new send response")
	}
	if !sentPartialLastMessageMatches(&imessage.Message{Text: "new", IsSender: &isSender}, "new") {
		t.Fatal("matching own partial last message should be usable")
	}
	isNotSender := false
	if sentPartialLastMessageMatches(&imessage.Message{Text: "new", IsSender: &isNotSender}, "new") {
		t.Fatal("incoming partial last message must not be used as the own send response")
	}
}

func TestBestEffortAutomationErrorClassifier(t *testing.T) {
	if !shouldIgnoreBestEffortAutomationError(errors.New("Initialized MessagesController in an invalid state:\nmwFrameValid=failure(Could not get main Messages window)")) {
		t.Fatal("expected missing Messages main window errors to be best-effort for implicit read receipts")
	}
	if shouldIgnoreBestEffortAutomationError(errors.New("operation timed out after 45s")) {
		t.Fatal("generic send timeouts must not be ignored")
	}
	if shouldIgnoreBestEffortAutomationError(nil) {
		t.Fatal("nil errors must not be classified as ignored")
	}
}

func TestClientLoginStateAndEventLoopReset(t *testing.T) {
	client := &Client{}
	if client.IsLoggedIn() {
		t.Fatal("new client should not report logged in")
	}

	first := client.resetEventLoop()
	client.loggedIn.Store(true)
	client.Disconnect()
	if client.IsLoggedIn() {
		t.Fatal("disconnect should clear logged-in state")
	}
	select {
	case <-first:
	default:
		t.Fatal("disconnect should close the active event loop channel")
	}

	second := client.resetEventLoop()
	select {
	case <-second:
		t.Fatal("reset should create a fresh open event loop channel")
	default:
	}
	client.Disconnect()
	select {
	case <-second:
	default:
		t.Fatal("disconnect should close the reset event loop channel")
	}
}

func TestMessageMetadataAndSearchFormatting(t *testing.T) {
	meta := messageDBMetadata(imessage.Message{
		ThreadID: "thread",
		Cursor:   "cursor",
		Attachments: []imessage.Attachment{{
			ID:     "att-1",
			SrcURL: "file:///tmp/photo.jpg",
		}},
	})
	if !meta.Attachment || !reflect.DeepEqual(meta.AttachmentIDs, []string{"att-1"}) || !reflect.DeepEqual(meta.AttachmentURLs, []string{"file:///tmp/photo.jpg"}) {
		t.Fatalf("unexpected message metadata: %#v", meta)
	}

	result := formatSearchResults([]imessage.Message{{
		ID:       "msg-1",
		ThreadID: "thread-1",
		Text:     "hello   world",
	}, {
		ID:       "msg-2",
		ThreadID: "thread-2",
		Attachments: []imessage.Attachment{{
			FileName: "image.png",
		}},
	}}, true)
	if !strings.Contains(result, "`thread-1` `msg-1` hello world") || !strings.Contains(result, "`thread-2` `msg-2` image.png") {
		t.Fatalf("unexpected search result:\n%s", result)
	}

	truncated := truncate("ååååå", 4)
	if truncated != "å..." {
		t.Fatalf("truncate should be rune-safe, got %q", truncated)
	}
}

func TestActivityStatusFormatting(t *testing.T) {
	status := formatActivityStatus(&imessage.ActivityStatus{
		ActivityType:       "typing",
		PresenceStatus:     "dnd_can_notify",
		DidObservePresence: true,
	})
	if !strings.Contains(status, "Activity: `typing`") || !strings.Contains(status, "Presence: `dnd_can_notify`") {
		t.Fatalf("unexpected activity status:\n%s", status)
	}

	unknown := formatActivityStatus(&imessage.ActivityStatus{})
	if !strings.Contains(unknown, "Activity: `none`") || !strings.Contains(unknown, "Presence: `unknown`") {
		t.Fatalf("unexpected unknown activity status:\n%s", unknown)
	}
}
