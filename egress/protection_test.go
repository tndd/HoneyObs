//go:build linux && arm64

package main

import (
	"encoding/base64"
	"strings"
	"testing"
)

func TestPrivateRecipientNeverFallsBack(t *testing.T) {
	encode := func(s string) string { return "honeyobs.allowedmail=" + base64.StdEncoding.EncodeToString([]byte(s)) }
	mail := "owner+qa@example.com"
	for _, input := range []string{"", "honeyobs.host=test.invalid"} {
		got, err := privateRecipient(input)
		if err != nil || got != "" {
			t.Fatalf("public input: %q %v", got, err)
		}
	}
	got, err := privateRecipient("honeyobs.host=test.invalid " + encode(mail))
	if err != nil || got != mail {
		t.Fatalf("private input: %q %v", got, err)
	}
	for _, input := range []string{encode(""), "honeyobs.allowedmail=%%%", encode(mail) + " " + encode(mail), encode("*@example.com"), encode("a@example.com,b@example.com"), encode("a@example.com\n"), encode("a@example.com\r\nHost:evil"), encode("a@localhost"), encode("a@-example.com")} {
		if _, err := privateRecipient(input); err == nil {
			t.Fatalf("invalid recipient accepted: %q", input)
		}
	}
}

func TestCloudflaredProtectionArgs(t *testing.T) {
	args, env, err := cloudflaredCommand("test.invalid", "owner@example.com")
	if err != nil || strings.Count(strings.Join(args, " "), "--allowed-mail owner@example.com") != 1 || !strings.Contains(strings.Join(env, " "), "HTTPS_PROXY=http://127.0.0.1:7003") {
		t.Fatal("protected mode missing", args, env, err)
	}
	args, env, err = cloudflaredCommand("test.invalid", "")
	if err != nil || strings.Contains(strings.Join(args, " "), "--allowed-mail") || strings.Contains(strings.Join(env, " "), "PROXY") {
		t.Fatal("public mode changed")
	}
	for _, mail := range []string{"*", "*@example.com", "one@example.com,two@example.com", "owner@example.com\n"} {
		args, env, err = cloudflaredCommand("test.invalid", mail)
		if err == nil || args != nil || env != nil {
			t.Fatal("invalid mode fell back to public")
		}
	}
}

func TestAuthConnectFixedDestination(t *testing.T) {
	valid := "CONNECT login.trycloudflare.com:443 HTTP/1.1\r\nHost: login.trycloudflare.com:443\r\nUser-Agent: Go-http-client/1.1\r\n\r\n"
	if !allowsAuthConnect(valid) {
		t.Fatal("valid CONNECT denied")
	}
	for _, invalid := range []string{
		strings.ReplaceAll(valid, "login.trycloudflare.com", "169.254.169.254"),
		strings.ReplaceAll(valid, "login.trycloudflare.com", "login.trycloudflare.com.attacker.invalid"),
		strings.Replace(valid, "CONNECT ", "GET ", 1),
		strings.Replace(valid, "Host: login.trycloudflare.com:443", "Host: example.com:443", 1),
		strings.Replace(valid, "User-Agent:", "Host: login.trycloudflare.com:443\r\nUser-Agent:", 1),
		strings.Replace(valid, "User-Agent:", "Transfer-Encoding: chunked\r\nUser-Agent:", 1),
		strings.Replace(valid, "User-Agent:", "Content-Length: 1\r\nUser-Agent:", 1),
		strings.ReplaceAll(valid, "\r\n", "\n"), valid + "payload",
		strings.Replace(valid, "Go-http-client/1.1", strings.Repeat("a", 4096), 1),
	} {
		if allowsAuthConnect(invalid) {
			t.Fatal("foreign/malformed CONNECT accepted")
		}
	}
}
