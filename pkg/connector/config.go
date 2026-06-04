package connector

import (
	_ "embed"

	up "go.mau.fi/util/configupgrade"
)

//go:embed example-config.yaml
var ExampleConfig string

type Config struct {
	DataDir              string `yaml:"data_dir"`
	Verbose              bool   `yaml:"verbose"`
	UseSecondaryInstance bool   `yaml:"use_secondary_instance"`
	EventPollTimeoutMS   int    `yaml:"event_poll_timeout_ms"`
}

func upgradeConfig(helper up.Helper) {
	helper.Copy(up.Str, "data_dir")
	helper.Copy(up.Bool, "verbose")
	helper.Copy(up.Bool, "use_secondary_instance")
	helper.Copy(up.Int, "event_poll_timeout_ms")
}

func (c *Connector) GetConfig() (string, any, up.Upgrader) {
	return ExampleConfig, &c.Config, up.SimpleUpgrader(upgradeConfig)
}
