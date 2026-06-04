package connector

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/beeper/platform-imessage/pkg/imessage"
	"github.com/beeper/platform-imessage/pkg/imessageid"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
	"maunium.net/go/mautrix/bridgev2/networkid"
)

type Connector struct {
	Bridge *bridgev2.Bridge
	Config Config
}

var _ bridgev2.NetworkConnector = (*Connector)(nil)
var _ bridgev2.StoppableNetwork = (*Connector)(nil)

func (c *Connector) Init(br *bridgev2.Bridge) {
	c.Bridge = br
}

func (c *Connector) Start(ctx context.Context) error {
	dataDir := c.Config.DataDir
	if dataDir == "" {
		dataDir = "imessage-data"
	}
	if !filepath.IsAbs(dataDir) {
		abs, err := filepath.Abs(dataDir)
		if err != nil {
			return fmt.Errorf("failed to resolve iMessage data dir: %w", err)
		}
		dataDir = abs
	}
	if err := os.MkdirAll(dataDir, 0o700); err != nil {
		return fmt.Errorf("failed to create iMessage data dir: %w", err)
	}
	return imessage.Init(dataDir, c.Config.Verbose, c.Config.UseSecondaryInstance)
}

func (c *Connector) Stop() {
	if err := imessage.Dispose(); err != nil && c.Bridge != nil {
		c.Bridge.Log.Warn().Err(err).Msg("Failed to dispose iMessage bridge runtime")
	}
}

func (c *Connector) GetName() bridgev2.BridgeName {
	return bridgev2.BridgeName{
		DisplayName:          "iMessage",
		NetworkURL:           "https://www.apple.com/ios/messages/",
		NetworkID:            "imessage",
		BeeperBridgeType:     "github.com/beeper/platform-imessage",
		DefaultPort:          29340,
		DefaultCommandPrefix: "!imessage",
	}
}

func (c *Connector) GetDBMetaTypes() database.MetaTypes {
	return database.MetaTypes{
		UserLogin: func() any { return &imessageid.UserLoginMetadata{} },
		Portal:    func() any { return &imessageid.PortalMetadata{} },
		Ghost:     func() any { return &imessageid.GhostMetadata{} },
		Message:   func() any { return &imessageid.MessageMetadata{} },
	}
}

func (c *Connector) LoadUserLogin(ctx context.Context, login *bridgev2.UserLogin) error {
	login.Client = &Client{
		Main:          c,
		UserLogin:     login,
		IM:            imessage.NewClient(),
		stopEventLoop: make(chan struct{}),
	}
	return nil
}

func portalKey(threadID string, receiver networkid.UserLoginID) networkid.PortalKey {
	return networkid.PortalKey{
		ID:       imessageid.MakePortalID(threadID),
		Receiver: receiver,
	}
}
