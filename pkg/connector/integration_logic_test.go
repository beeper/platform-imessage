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
	})
	if cursorPage == nil || cursorPage.Cursor != "cursor-1" || cursorPage.Direction != "after" {
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

func TestCapabilitiesDoNotAdvertiseUnsupportedGroupCreation(t *testing.T) {
	conn := &Connector{}
	general := conn.GetCapabilities()
	if !general.Provisioning.ResolveIdentifier.CreateDM {
		t.Fatal("expected CreateDM to be advertised")
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
