package connector

import (
	_ "embed"

	up "go.mau.fi/util/configupgrade"
)

//go:embed example-config.yaml
var ExampleConfig string

type Config struct {
	DataDir                  string `yaml:"data_dir"`
	Verbose                  bool   `yaml:"verbose"`
	UseSecondaryInstance     bool   `yaml:"use_secondary_instance"`
	CoordinateWindow         bool   `yaml:"coordinate_window"`
	EventPollTimeoutMS       int    `yaml:"event_poll_timeout_ms"`
	SkipPermissionValidation *bool  `yaml:"skip_permission_validation"`
}

func upgradeConfig(helper up.Helper) {
	helper.Copy(up.Str, "data_dir")
	helper.Copy(up.Bool, "verbose")
	helper.Copy(up.Bool, "use_secondary_instance")
	helper.Copy(up.Bool, "coordinate_window")
	helper.Copy(up.Int, "event_poll_timeout_ms")
	helper.Copy(up.Bool, "skip_permission_validation")
}

func (c *Connector) GetConfig() (string, any, up.Upgrader) {
	return ExampleConfig, &c.Config, up.SimpleUpgrader(upgradeConfig)
}

func (c *Config) ShouldSkipPermissionValidation() bool {
	return c.SkipPermissionValidation == nil || *c.SkipPermissionValidation
}
