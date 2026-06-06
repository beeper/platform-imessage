package connector

import (
	"context"
	"fmt"
	"strings"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
)

const (
	loginFlowLocal       = "local"
	loginStepPermissions = "com.beeper.imessage.login.permissions"
	loginStepDone        = "com.beeper.imessage.login.complete"
	loginFieldConfirm    = "permissions_ready"
)

func (c *Connector) GetLoginFlows() []bridgev2.LoginFlow {
	return []bridgev2.LoginFlow{{
		Name:        "Local Messages.app",
		Description: "Use the Apple ID currently signed in to Messages.app on this Mac.",
		ID:          loginFlowLocal,
	}}
}

func (c *Connector) CreateLogin(ctx context.Context, user *bridgev2.User, flowID string) (bridgev2.LoginProcess, error) {
	if flowID != loginFlowLocal {
		return nil, fmt.Errorf("invalid login flow ID %q", flowID)
	}
	return &LocalLogin{
		Main: c,
		User: user,
		IM:   imessage.NewClient(),
	}, nil
}

type LocalLogin struct {
	Main *Connector
	User *bridgev2.User
	IM   *imessage.Client
}

var _ bridgev2.LoginProcess = (*LocalLogin)(nil)
var _ bridgev2.LoginProcessUserInput = (*LocalLogin)(nil)

func (l *LocalLogin) Start(ctx context.Context) (*bridgev2.LoginStep, error) {
	if err := l.ensureOnlyLocalLoginOwner(ctx); err != nil {
		return nil, err
	}

	if l.Main.Config.ShouldSkipPermissionValidation() {
		return l.complete(ctx)
	}

	authStatus, err := l.IM.AuthorizationStatus()
	if err != nil {
		return nil, fmt.Errorf("failed to check local iMessage permissions: %w", err)
	}
	if authStatus.Authorized {
		return l.complete(ctx)
	}
	return l.permissionStep(authStatus), nil
}

func (l *LocalLogin) SubmitUserInput(ctx context.Context, _ map[string]string) (*bridgev2.LoginStep, error) {
	if err := l.ensureOnlyLocalLoginOwner(ctx); err != nil {
		return nil, err
	}

	if l.Main.Config.ShouldSkipPermissionValidation() {
		return l.complete(ctx)
	}

	authStatus, err := l.IM.AuthorizationStatus()
	if err != nil {
		return nil, fmt.Errorf("failed to check local iMessage permissions: %w", err)
	}
	if authStatus.Authorized {
		return l.complete(ctx)
	}

	authStatus, err = l.IM.RequestAuthorization("all")
	if err != nil {
		return nil, fmt.Errorf("failed to request local iMessage permissions: %w", err)
	}
	if authStatus.Authorized {
		return l.complete(ctx)
	}

	return l.permissionStep(authStatus), nil
}

func (l *LocalLogin) complete(ctx context.Context) (*bridgev2.LoginStep, error) {
	currentUser, err := l.IM.CurrentUser()
	if err != nil {
		return nil, fmt.Errorf("failed to get local iMessage user: %w", err)
	}

	loginID := l.localUserLoginID(currentUser.ID)
	existingLogins := l.loginsForUser()
	if len(existingLogins) > 1 {
		return nil, fmt.Errorf("%s already has multiple local iMessage logins; remove the extra logins before reconnecting", l.User.MXID)
	}
	if len(existingLogins) == 1 && existingLogins[0].ID == loginID {
		existing := existingLogins[0]
		loginID = existing.ID
	}
	remoteName := currentUser.DisplayText
	if remoteName == "" {
		remoteName = currentUser.Email
	}
	if remoteName == "" {
		remoteName = currentUser.PhoneNumber
	}
	if remoteName == "" {
		remoteName = currentUser.ID
	}

	ul, err := l.User.NewLogin(ctx, &database.UserLogin{
		ID:         loginID,
		RemoteName: remoteName,
		RemoteProfile: status.RemoteProfile{
			Name:  currentUser.DisplayText,
			Email: currentUser.Email,
			Phone: currentUser.PhoneNumber,
		},
		Metadata: &imessageid.UserLoginMetadata{
			DisplayText: currentUser.DisplayText,
			Email:       currentUser.Email,
			PhoneNumber: currentUser.PhoneNumber,
		},
	}, &bridgev2.NewLoginParams{
		DeleteOnConflict: false,
	})
	if err != nil {
		return nil, fmt.Errorf("failed to create iMessage login: %w", err)
	}

	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeComplete,
		StepID:       loginStepDone,
		Instructions: fmt.Sprintf("Logged in to local iMessage account %s", remoteName),
		CompleteParams: &bridgev2.LoginCompleteParams{
			UserLoginID: ul.ID,
			UserLogin:   ul,
		},
	}, nil
}

func (l *LocalLogin) localUserLoginID(currentUserID string) networkid.UserLoginID {
	if l.Main != nil && l.Main.Bridge != nil && l.Main.Bridge.Bot != nil {
		localpart, _, ok := strings.Cut(strings.TrimPrefix(string(l.Main.Bridge.Bot.GetMXID()), "@"), ":")
		if ok {
			localpart = strings.TrimSuffix(localpart, "bot")
			if localpart != "" {
				return networkid.UserLoginID(localpart)
			}
		}
	}
	return imessageid.MakeUserLoginID(currentUserID)
}

func (l *LocalLogin) permissionStep(status *imessage.AuthorizationStatus) *bridgev2.LoginStep {
	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeUserInput,
		StepID:       loginStepPermissions,
		Instructions: permissionInstructions(status),
		UserInputParams: &bridgev2.LoginUserInputParams{
			Fields: []bridgev2.LoginInputDataField{{
				Type:        bridgev2.LoginInputFieldTypeSelect,
				ID:          loginFieldConfirm,
				Name:        "Permissions",
				Description: "Grant the required macOS permissions, then continue.",
				Options:     []string{"Permissions granted"},
			}},
		},
	}
}

func permissionInstructions(status *imessage.AuthorizationStatus) string {
	var lines []string
	lines = append(lines,
		"Grant the missing local iMessage permissions on this Mac, then choose Permissions granted and submit.",
		"",
	)
	for _, permission := range status.Permissions {
		if !permission.Required {
			continue
		}
		marker := "[ ]"
		if permission.Authorized {
			marker = "[ok]"
		}
		line := fmt.Sprintf("%s %s", marker, permission.Title)
		if permission.Detail != "" {
			line += " - " + permission.Detail
		}
		lines = append(lines, line)
	}
	lines = append(lines, "", "If a settings window opened, enable this bridge there and return to Beeper.")
	return strings.Join(lines, "\n")
}

func (l *LocalLogin) loginsForUser() []*bridgev2.UserLogin {
	var logins []*bridgev2.UserLogin
	for _, login := range l.Main.Bridge.GetAllCachedUserLogins() {
		if login.UserMXID == l.User.MXID {
			logins = append(logins, login)
		}
	}
	return logins
}

func (l *LocalLogin) ensureOnlyLocalLoginOwner(ctx context.Context) error {
	for _, login := range l.Main.Bridge.GetAllCachedUserLogins() {
		if login.UserMXID != l.User.MXID {
			return fmt.Errorf("local iMessage is already connected by %s; this bridge can only have one local iMessage login", login.UserMXID)
		}
	}
	userIDs, err := l.Main.Bridge.DB.UserLogin.GetAllUserIDsWithLogins(ctx)
	if err != nil {
		return fmt.Errorf("failed to check existing iMessage logins: %w", err)
	}
	for _, userID := range userIDs {
		if userID != l.User.MXID {
			return fmt.Errorf("local iMessage is already connected by %s; this bridge can only have one local iMessage login", userID)
		}
	}
	existingForUser, err := l.Main.Bridge.DB.UserLogin.GetAllForUser(ctx, l.User.MXID)
	if err != nil {
		return fmt.Errorf("failed to check existing iMessage logins for %s: %w", l.User.MXID, err)
	}
	if len(existingForUser) > 1 {
		return fmt.Errorf("%s already has multiple local iMessage logins; this bridge can only have one local iMessage login", l.User.MXID)
	}
	return nil
}

func (l *LocalLogin) Cancel() {}
