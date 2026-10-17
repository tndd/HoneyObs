package main

import (
	"encoding/base64"
	"errors"
	"io"
	"net"
	"regexp"
	"strings"
	"time"
)

var recipientPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+\-]{0,63}@[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9\-]*[A-Za-z0-9])?)+$`)

func validRecipient(value string) bool {
	return len(value) <= 254 && recipientPattern.MatchString(value)
}

// 空・重複・壊れた指定をpublicへ読み替えない。未指定だけが従来のpublic。
func privateRecipient(cmdline string) (string, error) {
	value, count := "", 0
	for _, field := range strings.Fields(cmdline) {
		if strings.HasPrefix(field, "honeyobs.allowedmail=") {
			count++
			decoded, err := base64.StdEncoding.Strict().DecodeString(strings.TrimPrefix(field, "honeyobs.allowedmail="))
			if err != nil || !validRecipient(string(decoded)) {
				return "", errors.New("invalid private recipient")
			}
			value = string(decoded)
		}
	}
	if count > 1 {
		return "", errors.New("duplicate private recipient")
	}
	return value, nil
}

func cloudflaredCommand(origin, recipient string) ([]string, []string, error) {
	args := []string{"cloudflared", "tunnel", "--config", "/config.yml", "--no-autoupdate", "--url", "http://127.0.0.1:7000", "--http-host-header", origin, "--protocol", "http2", "--edge", "127.0.0.1:7844", "--quick-service", "http://127.0.0.1:7002", "--ha-connections", "1", "--metrics", "127.0.0.1:0"}
	env := []string{"HOME=/tmp", "GODEBUG=netdns=go"}
	if recipient != "" {
		if !validRecipient(recipient) {
			return nil, nil, errors.New("invalid private recipient")
		}
		args = append(args, "--allowed-mail", recipient)
		// 署名鍵取得に使うGo標準HTTP transportだけを固定CONNECT入口へ向ける。
		env = append(env, "HTTPS_PROXY=http://127.0.0.1:7003")
	}
	return args, env, nil
}

func allowsAuthConnect(header string) bool {
	if len(header) > 4096 || !strings.HasSuffix(header, "\r\n\r\n") {
		return false
	}
	lines := strings.Split(header, "\r\n")
	if lines[0] != "CONNECT login.trycloudflare.com:443 HTTP/1.1" {
		return false
	}
	hosts := 0
	for _, line := range lines[1 : len(lines)-2] {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			return false
		}
		switch strings.ToLower(key) {
		case "host":
			hosts++
			if strings.TrimSpace(value) != "login.trycloudflare.com:443" {
				return false
			}
		case "user-agent", "proxy-connection":
		default:
			return false
		}
	}
	return hosts == 1
}

func authProxy(local net.Conn) {
	defer local.Close()
	local.SetReadDeadline(time.Now().Add(3 * time.Second))
	header := make([]byte, 0, 256)
	for len(header) < 4096 && !strings.HasSuffix(string(header), "\r\n\r\n") {
		var b [1]byte
		if _, err := io.ReadFull(local, b[:]); err != nil {
			return
		}
		header = append(header, b[0])
	}
	if !allowsAuthConnect(string(header)) {
		return
	}
	local.SetReadDeadline(time.Time{})
	if _, err := io.WriteString(local, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	// 宛先は入力から作らない。ホスト側でもTLSのSNIと固定IP/portを独立検査する。
	forward(local, 9003)
}
