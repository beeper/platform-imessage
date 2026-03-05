//go:build darwin

package connector

import (
	"context"
	"fmt"

	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
	"maunium.net/go/mautrix/bridgev2/status"
)

const (
	LoginFlowIDLocalMac = "local-mac"

	LoginStepIDGrantAccess = "com.beeper.imessage.grant_access"
	LoginStepIDComplete    = "com.beeper.imessage.complete"
)

type IMLogin struct {
	Main   *IMConnector
	User   *bridgev2.User
	FlowID string
}

var _ bridgev2.LoginProcessDisplayAndWait = (*IMLogin)(nil)

func (il *IMLogin) Start(ctx context.Context) (*bridgev2.LoginStep, error) {
	if il.FlowID != LoginFlowIDLocalMac {
		return nil, fmt.Errorf("unknown login flow ID %q", il.FlowID)
	}

	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeDisplayAndWait,
		StepID:       LoginStepIDGrantAccess,
		Instructions: "Grant Full Disk Access and any requested Accessibility permissions to the bridge process, keep Messages.app available, then continue.",
		DisplayAndWaitParams: &bridgev2.LoginDisplayAndWaitParams{
			Type: bridgev2.LoginDisplayTypeNothing,
		},
	}, nil
}

func (il *IMLogin) Wait(ctx context.Context) (*bridgev2.LoginStep, error) {
	var currentUser JSCurrentUser
	if err := il.Main.bridgeCLI().Run(ctx, "login", nil, &currentUser); err != nil {
		return nil, err
	} else if currentUser.ID == "" {
		return nil, fmt.Errorf("bridge cli returned empty current user")
	}

	displayName := currentUser.DisplayName
	if displayName == "" {
		displayName = currentUser.ID
	}

	userLogin, err := il.User.NewLogin(ctx, &database.UserLogin{
		ID:         networkid.UserLoginID(currentUser.ID),
		RemoteName: displayName,
		RemoteProfile: status.RemoteProfile{
			Name:  displayName,
			Email: currentUser.Email,
			Phone: currentUser.PhoneNumber,
		},
		Metadata: &UserLoginMetadata{
			CurrentUserID: currentUser.ID,
			DisplayName:   currentUser.DisplayName,
			Email:         currentUser.Email,
			PhoneNumber:   currentUser.PhoneNumber,
		},
	}, &bridgev2.NewLoginParams{
		DeleteOnConflict: false,
	})
	if err != nil {
		return nil, err
	}

	return &bridgev2.LoginStep{
		Type:         bridgev2.LoginStepTypeComplete,
		StepID:       LoginStepIDComplete,
		Instructions: fmt.Sprintf("Connected to Messages as %s", displayName),
		CompleteParams: &bridgev2.LoginCompleteParams{
			UserLoginID: userLogin.ID,
			UserLogin:   userLogin,
		},
	}, nil
}

func (il *IMLogin) Cancel() {}
