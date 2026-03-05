//go:build darwin

package main

import (
	"maunium.net/go/mautrix/bridgev2/matrix/mxmain"

	"github.com/beeper/platform-imessage/pkg/connector"
)

var (
	Tag       = "dev"
	Commit    = "unknown"
	BuildTime = "unknown"
)

func main() {
	m := mxmain.BridgeMain{
		Name:        "mautrix-imessage",
		Description: "A macOS-only BridgeV2 bridge for iMessage",
		URL:         "https://github.com/beeper/platform-imessage",
		Version:     "0.1.0",
		Connector:   &connector.IMConnector{},
	}
	m.InitVersion(Tag, Commit, BuildTime)
	m.Run()
}
