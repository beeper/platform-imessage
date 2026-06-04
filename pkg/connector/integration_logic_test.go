package connector

import (
	"reflect"
	"strings"
	"testing"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/commands"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
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
	dmIDs := syntheticPortalIDsForThread(imessage.Thread{
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{{ID: "+15551234567"}}},
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
			{ID: "a@example.com"},
		}},
	})
	if !reflect.DeepEqual(groupIDs, []string{"group;-;a@example.com,b@example.com"}) {
		t.Fatalf("unexpected group synthetic IDs: %#v", groupIDs)
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
	thread := imessage.Thread{
		ID:     "iMessage;-;chat",
		Title:  "Project",
		Type:   imessage.ThreadTypeGroup,
		ImgURL: "asset://account/group-avatar/1.heic",
		Participants: imessage.Page[imessage.User]{Items: []imessage.User{
			{ID: "alice@example.com", FullName: "Alice", ImgURL: "asset://account/alice/1.heic"},
			{ID: "bob@example.com", FullName: "Bob"},
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
	if senderID != "bob@example.com" || reactionKey != "heart" {
		t.Fatalf("unexpected fallback reaction sender/key: %q %q", senderID, reactionKey)
	}

	backfillReaction := backfillReactionFromIMessage(imessage.Reaction{
		ID:            "alice@example.comlike",
		ReactionKey:   "like",
		ParticipantID: "alice@example.com",
	})
	if backfillReaction.Sender.Sender != "alice@example.com" || backfillReaction.EmojiID != "alice@example.comlike" {
		t.Fatalf("unexpected backfill reaction: %#v", backfillReaction)
	}
	meta, ok := backfillReaction.DBMetadata.(*imessageid.ReactionMetadata)
	if !ok || meta.ReactionID != "alice@example.comlike" || meta.ReactionKey != "like" {
		t.Fatalf("unexpected backfill reaction metadata: %#v", backfillReaction.DBMetadata)
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

	if got := reactionKeyFromDBReaction(&database.Reaction{Emoji: "😂"}); got != "😂" {
		t.Fatalf("expected emoji fallback, got %q", got)
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

func TestCapabilitiesDoNotAdvertiseUnsupportedGroupCreation(t *testing.T) {
	conn := &Connector{}
	general := conn.GetCapabilities()
	if !general.Provisioning.ResolveIdentifier.CreateDM {
		t.Fatal("expected CreateDM to be advertised")
	}
	if !general.Provisioning.ResolveIdentifier.LookupEmail || !general.Provisioning.ResolveIdentifier.AnyPhone {
		t.Fatalf("expected email lookup and any-phone capabilities for iMessage identifiers: %#v", general.Provisioning.ResolveIdentifier)
	}
	if !general.Provisioning.ResolveIdentifier.ContactList || !general.Provisioning.ResolveIdentifier.Search {
		t.Fatalf("expected contact list and search capabilities: %#v", general.Provisioning.ResolveIdentifier)
	}
	if len(general.Provisioning.GroupCreation) != 0 {
		t.Fatalf("standard group creation must not be advertised for iMessage initial-message flows: %#v", general.Provisioning.GroupCreation)
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
