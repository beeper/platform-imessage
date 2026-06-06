package imessageid

import (
	"fmt"
	"strings"

	"maunium.net/go/mautrix/bridgev2/networkid"
)

const MessagePartSeparator = "\x1f"

func MakeUserLoginID(currentUserID string) networkid.UserLoginID {
	if currentUserID == "" {
		return networkid.UserLoginID("default")
	}
	return networkid.UserLoginID(currentUserID)
}

func MakeUserID(userID string) networkid.UserID {
	return networkid.UserID(userID)
}

func MakePortalID(threadID string) networkid.PortalID {
	return networkid.PortalID(threadID)
}

func MakeMessageID(messageID string) networkid.MessageID {
	return networkid.MessageID(messageID)
}

func MakePartID(index int) networkid.PartID {
	if index == 0 {
		return ""
	}
	return networkid.PartID(fmt.Sprintf("%d", index))
}

func SplitMessagePartID(messageID networkid.MessageID) (networkid.MessageID, networkid.PartID) {
	id, part, ok := strings.Cut(string(messageID), MessagePartSeparator)
	if !ok {
		return messageID, ""
	}
	return networkid.MessageID(id), networkid.PartID(part)
}
