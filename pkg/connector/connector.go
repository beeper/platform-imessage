//go:build darwin

package connector

import (
	"context"
	_ "embed"
	"os"
	"path/filepath"

	"go.mau.fi/util/configupgrade"
	"maunium.net/go/mautrix/bridgev2"
	"maunium.net/go/mautrix/bridgev2/database"
)

type IMConnector struct {
	Bridge *bridgev2.Bridge
	Config Config

	js *JSBridge
}

type Config struct {
	NodePath string `yaml:"node_path"`
	CLIPath  string `yaml:"cli_path"`
	DataDir  string `yaml:"data_dir"`
}

type UserLoginMetadata struct {
	CurrentUserID string `json:"current_user_id"`
	DisplayName   string `json:"display_name,omitempty"`
	Email         string `json:"email,omitempty"`
	PhoneNumber   string `json:"phone_number,omitempty"`
}

var _ bridgev2.NetworkConnector = (*IMConnector)(nil)

func (c *Config) fillDefaults() {
	if c.NodePath == "" {
		c.NodePath = "node"
	}
	if c.CLIPath == "" {
		c.CLIPath = "dist/bridgev2/cli.js"
	}
	if c.DataDir == "" {
		homeDir, err := os.UserHomeDir()
		if err == nil && homeDir != "" {
			c.DataDir = filepath.Join(homeDir, "Library", "Application Support", "mautrix-imessage")
		} else {
			c.DataDir = ".mautrix-imessage"
		}
	}
}

func (ic *IMConnector) bridgeCLI() *JSBridge {
	if ic.js == nil {
		ic.Config.fillDefaults()
		ic.js = &JSBridge{Config: &ic.Config}
	}
	return ic.js
}

func (ic *IMConnector) Init(bridge *bridgev2.Bridge) {
	ic.Bridge = bridge
}

func (ic *IMConnector) Start(ctx context.Context) error {
	ic.Config.fillDefaults()
	return nil
}

func (ic *IMConnector) GetName() bridgev2.BridgeName {
	return bridgev2.BridgeName{
		DisplayName:          "iMessage",
		NetworkURL:           "https://support.apple.com/messages",
		NetworkID:            "imessage",
		BeeperBridgeType:     "local-imessage",
		DefaultCommandPrefix: "!imsg",
	}
}

func (ic *IMConnector) GetDBMetaTypes() database.MetaTypes {
	return database.MetaTypes{
		UserLogin: func() any {
			return &UserLoginMetadata{}
		},
	}
}

func (ic *IMConnector) GetCapabilities() *bridgev2.NetworkGeneralCapabilities {
	return &bridgev2.NetworkGeneralCapabilities{
		Provisioning: bridgev2.ProvisioningCapabilities{
			ResolveIdentifier: bridgev2.ResolveIdentifierCapabilities{
				CreateDM:    true,
				LookupPhone: true,
				LookupEmail: true,
				AnyPhone:    true,
			},
		},
	}
}

//go:embed example-config.yaml
var ExampleConfig string

func upgradeConfig(helper configupgrade.Helper) {
	helper.Copy(configupgrade.Str, "node_path")
	helper.Copy(configupgrade.Str, "cli_path")
	helper.Copy(configupgrade.Str, "data_dir")
}

func (ic *IMConnector) GetConfig() (example string, data any, upgrader configupgrade.Upgrader) {
	return ExampleConfig, &ic.Config, configupgrade.SimpleUpgrader(upgradeConfig)
}

func (ic *IMConnector) LoadUserLogin(ctx context.Context, login *bridgev2.UserLogin) error {
	metadata, _ := login.Metadata.(*UserLoginMetadata)
	login.Client = &IMClient{
		Main:      ic,
		UserLogin: login,
		Metadata:  metadata,
		loggedIn:  metadata != nil && metadata.CurrentUserID != "",
	}
	return nil
}

func (ic *IMConnector) GetLoginFlows() []bridgev2.LoginFlow {
	return []bridgev2.LoginFlow{{
		Name:        "Local Mac access",
		Description: "Grant the bridge access to Messages data on this Mac",
		ID:          LoginFlowIDLocalMac,
	}}
}

func (ic *IMConnector) CreateLogin(ctx context.Context, user *bridgev2.User, flowID string) (bridgev2.LoginProcess, error) {
	return &IMLogin{
		Main:   ic,
		User:   user,
		FlowID: flowID,
	}, nil
}

func (ic *IMConnector) GetBridgeInfoVersion() (info, capabilities int) {
	return 1, 1
}
