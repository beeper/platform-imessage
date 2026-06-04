package connector

import (
	"context"
	"fmt"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/status"
)

const (
	loginFlowLocal = "local"
	loginStepLocal = "com.beeper.imessage.login.local"
	loginStepDone  = "com.beeper.imessage.login.complete"
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

func (l *LocalLogin) Start(ctx context.Context) (*bridgev2.LoginStep, error) {
	currentUser, err := l.IM.CurrentUser()
	if err != nil {
		return nil, fmt.Errorf("failed to get local iMessage user: %w", err)
	}

	loginID := imessageid.MakeUserLoginID(currentUser.ID)
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
		DeleteOnConflict: true,
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

func (l *LocalLogin) Cancel() {}
