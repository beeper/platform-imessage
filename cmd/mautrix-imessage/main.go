package main

import (
	"maunium.net/go/mautrix/bridgev2/matrix/mxmain"

	"github.com/beeper/platform-imessage/pkg/connector"
)

var (
	Tag       = "unknown"
	Commit    = "unknown"
	BuildTime = "unknown"
)

var m = mxmain.BridgeMain{
	Name:        "mautrix-imessage",
	URL:         "https://github.com/beeper/platform-imessage",
	Description: "A Matrix-iMessage bridge using platform-imessage and mautrix bridgev2.",
	Version:     "0.1.0",
	Connector:   &connector.Connector{},
}

func main() {
	m.InitVersion(Tag, Commit, BuildTime)
	m.Run()
}
