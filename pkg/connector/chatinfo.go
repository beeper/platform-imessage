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
	_ bridgev2.GhostDMCreatingNetworkAPI     = (*Client)(nil)
	_ bridgev2.GroupCreatingNetworkAPI       = (*Client)(nil)
	_ bridgev2.IdentifierValidatingNetwork   = (*Connector)(nil)
)

func (c *Connector) ValidateUserID(id networkid.UserID) bool {
	return validIMessageIdentifier(string(id))
}

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
	return c.userInfoFromUser(imessage.User{ID: string(ghost.ID)}), nil
}

func (c *Client) ResolveIdentifier(ctx context.Context, identifier string, createChat bool) (*bridgev2.ResolveIdentifierResponse, error) {
	identifier = normalizeIMessageIdentifier(identifier)
	if !validIMessageIdentifier(identifier) {
		return nil, matrixUnsupported("invalid iMessage identifier")
	}
	user := imessage.User{ID: identifier, Username: identifier}
	resp := &bridgev2.ResolveIdentifierResponse{
		UserID:   imessageid.MakeUserID(identifier),
		UserInfo: c.userInfoFromUser(user),
	}
	if createChat {
		resp.Chat = c.syntheticChatResponse([]string{identifier}, "")
	}
	return resp, nil
}

func (c *Client) CreateChatWithGhost(ctx context.Context, ghost *bridgev2.Ghost) (*bridgev2.CreateChatResponse, error) {
	if ghost == nil || !validIMessageIdentifier(string(ghost.ID)) {
		return nil, matrixUnsupported("invalid iMessage user ID")
	}
	return c.syntheticChatResponse([]string{string(ghost.ID)}, ""), nil
}

func (c *Client) CreateGroup(ctx context.Context, params *bridgev2.GroupCreateParams) (*bridgev2.CreateChatResponse, error) {
	if params == nil {
		return nil, matrixUnsupported("missing iMessage group parameters")
	}
	selfIdentifiers := c.currentUserIdentifiers()
	participants := make([]string, 0, len(params.Participants))
	for _, participant := range params.Participants {
		participant := normalizeIMessageIdentifier(string(participant))
		if selfIdentifiers[participant] {
			continue
		}
		if !validIMessageIdentifier(participant) {
			return nil, matrixUnsupported("invalid iMessage group participant")
		}
		participants = append(participants, participant)
	}
	if len(participants) < 2 {
		return nil, matrixUnsupported("iMessage groups need at least two recipients")
	}
	name := ""
	if params.Name != nil {
		name = strings.TrimSpace(params.Name.Name)
	}
	existingThread, err := c.existingThreadWithParticipants(participants)
	if err != nil {
		return nil, err
	}
	if existingThread != nil {
		return c.chatResponseFromThread(*existingThread), nil
	}
	return c.syntheticChatResponse(participants, name), nil
}

func (c *Client) currentUserIdentifiers() map[string]bool {
	identifiers := map[string]bool{}
	if c == nil || c.IM == nil {
		return identifiers
	}
	currentUser, err := c.IM.CurrentUser()
	if err != nil || currentUser == nil {
		return identifiers
	}
	for _, identifier := range []string{currentUser.ID, currentUser.Email, currentUser.PhoneNumber} {
		identifier = normalizeIMessageIdentifier(identifier)
		if identifier != "" {
			identifiers[identifier] = true
			identifiers[canonicalIMessageIdentifier(identifier)] = true
		}
	}
	return identifiers
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
			if participant.ID == "" || isSelfParticipant(participant) {
				continue
			}
			info := c.userInfoFromUser(participant)
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

func normalizeIMessageIdentifier(identifier string) string {
	return strings.TrimSpace(identifier)
}

func canonicalIMessageIdentifier(identifier string) string {
	return strings.ToLower(normalizeIMessageIdentifier(identifier))
}

func canonicalPortalParticipantID(identifier string) string {
	canonical := canonicalIMessageIdentifier(identifier)
	if canonical == "" {
		return normalizeIMessageIdentifier(identifier)
	}
	return canonical
}

func validIMessageIdentifier(identifier string) bool {
	identifier = normalizeIMessageIdentifier(identifier)
	return identifier != "" &&
		!strings.Contains(identifier, ";-;") &&
		!strings.Contains(identifier, ",") &&
		!strings.ContainsAny(identifier, "\x00\r\n\t")
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
	for i, participant := range participants {
		participants[i] = canonicalPortalParticipantID(participant)
	}
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
			UserInfo:    c.userInfoFromUser(imessage.User{ID: participant, Username: participant}),
		})
	}
	members.Set(c.selfChatMember())
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

func (c *Client) chatResponseFromThread(thread imessage.Thread) *bridgev2.CreateChatResponse {
	return &bridgev2.CreateChatResponse{
		PortalKey:  portalKey(thread.ID, c.UserLogin.ID),
		PortalInfo: c.chatInfoFromThread(thread),
	}
}

func (c *Client) existingThreadWithParticipants(participants []string) (*imessage.Thread, error) {
	if c == nil || c.IM == nil {
		return nil, nil
	}
	expected := canonicalParticipantSet(participants)
	if len(expected) < 2 {
		return nil, nil
	}

	var pagination *imessage.Pagination
	for pageCount := 0; pageCount < 200; pageCount++ {
		page, err := c.IM.Chats(pagination)
		if err != nil {
			return nil, err
		}
		for _, thread := range page.Items {
			if thread.Type != imessage.ThreadTypeGroup && !threadIDIsGroup(thread.ID) {
				continue
			}
			if participantSetMatchesThread(expected, thread, c.currentUserIdentifiers()) {
				return &thread, nil
			}
		}
		if !page.HasMore || page.OldestCursor == "" {
			break
		}
		pagination = &imessage.Pagination{Cursor: page.OldestCursor, Direction: "before"}
	}
	return nil, nil
}

func canonicalParticipantSet(participants []string) map[string]struct{} {
	out := make(map[string]struct{}, len(participants))
	for _, participant := range participants {
		if canonical := canonicalIMessageIdentifier(participant); canonical != "" {
			out[canonical] = struct{}{}
		}
	}
	return out
}

func participantSetMatchesThread(expected map[string]struct{}, thread imessage.Thread, selfIdentifiers map[string]bool) bool {
	actual := make(map[string]struct{}, len(thread.Participants.Items))
	for _, participant := range thread.Participants.Items {
		canonical := canonicalIMessageIdentifier(participant.ID)
		if canonical == "" || isSelfParticipant(participant) || selfIdentifiers[normalizeIMessageIdentifier(participant.ID)] || selfIdentifiers[canonical] {
			continue
		}
		actual[canonical] = struct{}{}
	}
	if len(actual) != len(expected) {
		return false
	}
	for participant := range expected {
		if _, ok := actual[participant]; !ok {
			return false
		}
	}
	return true
}

func (c *Client) chatInfoFromThread(thread imessage.Thread) *bridgev2.ChatInfo {
	roomType := database.RoomTypeDefault
	if thread.Type == imessage.ThreadTypeSingle && !threadIDIsGroup(thread.ID) {
		roomType = database.RoomTypeDM
	}

	selfIdentifiers := c.currentUserIdentifiers()
	memberMap := bridgev2.ChatMemberMap{}
	for _, participant := range participantsForChatInfo(thread, roomType, selfIdentifiers) {
		if isSelfParticipant(participant) || selfIdentifiers[normalizeIMessageIdentifier(participant.ID)] {
			continue
		}
		userID := imessageid.MakeUserID(participant.ID)
		memberMap.Set(bridgev2.ChatMember{
			EventSender: bridgev2.EventSender{Sender: userID},
			Membership:  event.MembershipJoin,
			UserInfo:    c.userInfoFromUser(participant),
		})
	}
	memberMap.Set(c.selfChatMember())

	info := &bridgev2.ChatInfo{
		Members: &bridgev2.ChatMemberList{
			IsFull:           true,
			TotalMemberCount: len(memberMap),
			MemberMap:        memberMap,
		},
		Type:        &roomType,
		CanBackfill: true,
	}
	if thread.Title != "" {
		info.Name = &thread.Title
	}
	if thread.ImgURL != "" {
		info.Avatar = c.avatarFromURL(thread.ImgURL)
	}
	return info
}

func (c *Client) selfChatMember() bridgev2.ChatMember {
	return bridgev2.ChatMember{
		EventSender: bridgev2.EventSender{
			IsFromMe:    true,
			SenderLogin: c.UserLogin.ID,
			Sender:      c.GetUserID(),
			ForceDMUser: false,
		},
		Membership: event.MembershipJoin,
	}
}

func isSelfParticipant(participant imessage.User) bool {
	return participant.IsSelf != nil && *participant.IsSelf
}

func threadIDIsGroup(threadID string) bool {
	return strings.Contains(threadID, ";+;") || strings.HasPrefix(threadID, "group;-;")
}

func participantsForChatInfo(thread imessage.Thread, roomType database.RoomType, selfIdentifierMaps ...map[string]bool) []imessage.User {
	selfIdentifiers := map[string]bool{}
	if len(selfIdentifierMaps) > 0 && selfIdentifierMaps[0] != nil {
		selfIdentifiers = selfIdentifierMaps[0]
	}
	participants := make([]imessage.User, 0, len(thread.Participants.Items))
	for _, participant := range thread.Participants.Items {
		if participant.ID == "" || isSelfParticipant(participant) || selfIdentifiers[normalizeIMessageIdentifier(participant.ID)] {
			continue
		}
		participants = append(participants, participant)
	}
	if roomType != database.RoomTypeDM || len(participants) <= 1 {
		return participants
	}
	if identifier := singleThreadIdentifier(thread.ID); identifier != "" {
		for _, participant := range participants {
			if participant.ID == identifier {
				return []imessage.User{participant}
			}
		}
	}
	return participants[:1]
}

func singleThreadIdentifier(threadID string) string {
	parts := strings.SplitN(threadID, ";", 3)
	if len(parts) != 3 || parts[1] != "-" {
		return ""
	}
	switch parts[0] {
	case "any", "iMessage", "SMS", "RCS":
		return parts[2]
	default:
		return ""
	}
}

func (c *Client) userInfoFromUser(user imessage.User) *bridgev2.UserInfo {
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
	if user.ImgURL != "" {
		info.Avatar = c.avatarFromURL(user.ImgURL)
	}
	return info
}

func (c *Client) avatarFromURL(rawURL string) *bridgev2.Avatar {
	if rawURL == "" {
		return nil
	}
	return &bridgev2.Avatar{
		ID: networkid.AvatarID(rawURL),
		Get: func(ctx context.Context) ([]byte, error) {
			data, _, err := c.readAttachmentURL(ctx, rawURL, 0)
			return data, err
		},
	}
}

func receiver(login *bridgev2.UserLogin) networkid.UserLoginID {
	if login == nil {
		return ""
	}
	return login.ID
}
