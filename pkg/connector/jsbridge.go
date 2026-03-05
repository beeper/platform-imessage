//go:build darwin

package connector

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

type JSBridge struct {
	Config *Config
}

type jsRequest struct {
	Command     string `json:"command"`
	DataDirPath string `json:"dataDirPath"`
	Payload     any    `json:"payload,omitempty"`
}

type JSCurrentUser struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Email       string `json:"email,omitempty"`
	PhoneNumber string `json:"phoneNumber,omitempty"`
}

type JSParticipant struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName,omitempty"`
	Email       string `json:"email,omitempty"`
	PhoneNumber string `json:"phoneNumber,omitempty"`
}

type JSMessage struct {
	ID          string `json:"id"`
	ThreadID    string `json:"threadID"`
	SenderID    string `json:"senderID"`
	Text        string `json:"text,omitempty"`
	TimestampMS int64  `json:"timestampMs,omitempty"`
	ReplyToID   string `json:"replyToID,omitempty"`
}

type JSThread struct {
	ID           string          `json:"id"`
	Title        string          `json:"title,omitempty"`
	IsGroup      bool            `json:"isGroup"`
	IsSMS        bool            `json:"isSMS"`
	Participants []JSParticipant `json:"participants"`
	LastMessage  *JSMessage      `json:"lastMessage,omitempty"`
}

type JSSendMessageResponse struct {
	OK       bool        `json:"ok"`
	Messages []JSMessage `json:"messages"`
}

func (jb *JSBridge) Run(ctx context.Context, command string, payload any, output any) error {
	jb.Config.fillDefaults()

	cliPath := jb.Config.CLIPath
	if !filepath.IsAbs(cliPath) {
		absPath, err := filepath.Abs(cliPath)
		if err != nil {
			return fmt.Errorf("resolve cli path: %w", err)
		}
		cliPath = absPath
	}

	requestBytes, err := json.Marshal(jsRequest{
		Command:     command,
		DataDirPath: jb.Config.DataDir,
		Payload:     payload,
	})
	if err != nil {
		return fmt.Errorf("marshal js request: %w", err)
	}

	cmd := exec.CommandContext(ctx, jb.Config.NodePath, cliPath, string(requestBytes))
	cmd.Env = os.Environ()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err = cmd.Run(); err != nil {
		if stderr.Len() > 0 {
			return fmt.Errorf("run bridge cli: %w: %s", err, stderr.String())
		}
		return fmt.Errorf("run bridge cli: %w", err)
	}
	if output == nil || stdout.Len() == 0 {
		return nil
	}
	if err = json.Unmarshal(stdout.Bytes(), output); err != nil {
		return fmt.Errorf("decode bridge cli output: %w", err)
	}
	return nil
}
