package connector

import (
	"context"
	"sort"
	"strings"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/event"
)

var (
	_ bridgev2.IdentifierResolvingNetworkAPI = (*Client)(nil)
	_ bridgev2.ContactListingNetworkAPI      = (*Client)(nil)
	_ bridgev2.UserSearchingNetworkAPI       = (*Client)(nil)
)

func (c *Client) GetChatInfo(ctx context.Context, portal *bridgev2.Portal) (*bridgev2.ChatInfo, error) {
	thread, err := c.IM.Chat(string(portal.ID))
	if err != nil {
		return nil, err
	}
	if thread == nil {
		return &bridgev2.ChatInfo{}, nil
	}
	return c.chatInfoFromThread(*thread), nil
}

func (c *Client) GetUserInfo(ctx context.Context, ghost *bridgev2.Ghost) (*bridgev2.UserInfo, error) {
	return userInfoFromUser(imessage.User{ID: string(ghost.ID)}), nil
}

func (c *Client) ResolveIdentifier(ctx context.Context, identifier string, createChat bool) (*bridgev2.ResolveIdentifierResponse, error) {
	identifier = strings.TrimSpace(identifier)
	if identifier == "" {
		return nil, matrixUnsupported("empty iMessage identifier")
	}
	user := imessage.User{ID: identifier, Username: identifier}
	resp := &bridgev2.ResolveIdentifierResponse{
		UserID:   imessageid.MakeUserID(identifier),
		UserInfo: userInfoFromUser(user),
	}
	if createChat {
		resp.Chat = c.syntheticChatResponse([]string{identifier}, "")
	}
	return resp, nil
}

func (c *Client) GetContactList(ctx context.Context) ([]*bridgev2.ResolveIdentifierResponse, error) {
	contacts, err := c.contactResponses("")
	if err != nil {
		return nil, err
	}
	return contacts, nil
}

func (c *Client) SearchUsers(ctx context.Context, query string) ([]*bridgev2.ResolveIdentifierResponse, error) {
	return c.contactResponses(strings.ToLower(strings.TrimSpace(query)))
}

func (c *Client) contactResponses(filter string) ([]*bridgev2.ResolveIdentifierResponse, error) {
	page, err := c.IM.Chats(nil)
	if err != nil {
		return nil, err
	}
	seen := map[string]*bridgev2.ResolveIdentifierResponse{}
	for _, thread := range page.Items {
		for _, participant := range thread.Participants.Items {
			if participant.ID == "" {
				continue
			}
			info := userInfoFromUser(participant)
			if filter != "" && !contactMatches(filter, participant, info) {
				continue
			}
			seen[participant.ID] = &bridgev2.ResolveIdentifierResponse{
				UserID:   imessageid.MakeUserID(participant.ID),
				UserInfo: info,
			}
		}
	}
	out := make([]*bridgev2.ResolveIdentifierResponse, 0, len(seen))
	for _, resp := range seen {
		out = append(out, resp)
	}
	sort.Slice(out, func(i, j int) bool {
		return string(out[i].UserID) < string(out[j].UserID)
	})
	return out, nil
}

func contactMatches(filter string, user imessage.User, info *bridgev2.UserInfo) bool {
	fields := []string{user.ID, user.Username, user.PhoneNumber, user.Email, user.FullName, user.Nickname}
	if info != nil && info.Name != nil {
		fields = append(fields, *info.Name)
	}
	for _, field := range fields {
		if strings.Contains(strings.ToLower(field), filter) {
			return true
		}
	}
	return false
}

func (c *Client) syntheticChatResponse(participants []string, name string) *bridgev2.CreateChatResponse {
	sort.Strings(participants)
	threadID := "any;-;" + strings.Join(participants, ",")
	roomType := database.RoomTypeDM
	if len(participants) > 1 {
		roomType = database.RoomTypeDefault
		threadID = "group;-;" + strings.Join(participants, ",")
	}
	members := bridgev2.ChatMemberMap{}
	for _, participant := range participants {
		userID := imessageid.MakeUserID(participant)
		members.Set(bridgev2.ChatMember{
			EventSender: bridgev2.EventSender{Sender: userID},
			Membership:  event.MembershipJoin,
			UserInfo:    userInfoFromUser(imessage.User{ID: participant, Username: participant}),
		})
	}
	info := &bridgev2.ChatInfo{
		Type: &roomType,
		Members: &bridgev2.ChatMemberList{
			IsFull:           true,
			TotalMemberCount: len(members),
			MemberMap:        members,
		},
	}
	if name != "" {
		info.Name = &name
	}
	return &bridgev2.CreateChatResponse{
		PortalKey:  portalKey(threadID, c.UserLogin.ID),
		PortalInfo: info,
	}
}

func (c *Client) chatInfoFromThread(thread imessage.Thread) *bridgev2.ChatInfo {
	roomType := database.RoomTypeDefault
	if thread.Type == imessage.ThreadTypeSingle {
		roomType = database.RoomTypeDM
	}

	memberMap := bridgev2.ChatMemberMap{}
	for _, participant := range thread.Participants.Items {
		userID := imessageid.MakeUserID(participant.ID)
		memberMap.Set(bridgev2.ChatMember{
			EventSender: bridgev2.EventSender{Sender: userID},
			Membership:  event.MembershipJoin,
			UserInfo:    userInfoFromUser(participant),
		})
	}
	memberMap.Set(bridgev2.ChatMember{
		EventSender: bridgev2.EventSender{
			IsFromMe:    true,
			SenderLogin: c.UserLogin.ID,
			Sender:      c.GetUserID(),
			ForceDMUser: false,
		},
		Membership: event.MembershipJoin,
	})

	info := &bridgev2.ChatInfo{
		Members: &bridgev2.ChatMemberList{
			IsFull:           true,
			TotalMemberCount: len(memberMap),
			MemberMap:        memberMap,
		},
		Type: &roomType,
	}
	if thread.Title != "" {
		info.Name = &thread.Title
	}
	return info
}

func userInfoFromUser(user imessage.User) *bridgev2.UserInfo {
	displayName := user.FullName
	if displayName == "" {
		displayName = user.Nickname
	}
	if displayName == "" {
		displayName = user.Email
	}
	if displayName == "" {
		displayName = user.PhoneNumber
	}
	if displayName == "" {
		displayName = user.ID
	}

	info := &bridgev2.UserInfo{
		Name: &displayName,
	}
	return info
}

func receiver(login *bridgev2.UserLogin) networkid.UserLoginID {
	if login == nil {
		return ""
	}
	return login.ID
}
