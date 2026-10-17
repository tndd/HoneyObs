package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type qaTestTransport func(*http.Request) (*http.Response, error)

func (f qaTestTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
func qaTestKey() []byte                                                     { return bytes.Repeat([]byte{0x53}, 32) }
func qaTestCookie() string {
	return qaCookieName + "=" + base64.RawURLEncoding.EncodeToString(qaTestKey())
}

func TestQAConfigurationCannotBecomePublic(t *testing.T) {
	for _, input := range []string{"honeyobs.qaauth", "honeyobs.qaauth=", "honeyobs.qaauth=0", "honeyobs.qaauth=1 honeyobs.qaauth=1"} {
		if _, err := qaKeyRequired(input); err == nil {
			t.Fatal("malformed private mode accepted")
		}
	}
	if enabled, err := qaKeyRequired("quiet honeyobs.qaauth=1"); err != nil || !enabled {
		t.Fatal("private mode rejected")
	}
	if enabled, err := qaKeyRequired("quiet"); err != nil || enabled {
		t.Fatal("public mode changed")
	}
	encoded := base64.RawURLEncoding.EncodeToString(qaTestKey())
	if key, err := bridgeQAKey("1", encoded); err != nil || !bytes.Equal(key, qaTestKey()) {
		t.Fatal("key configuration rejected")
	}
	for _, values := range [][2]string{{"1", ""}, {"", encoded}, {"0", encoded}, {"1", encoded + "="}, {"1", "invalid"}} {
		if _, err := bridgeQAKey(values[0], values[1]); err == nil {
			t.Fatal("malformed key configuration accepted")
		}
	}
}

func TestQADeniesMissingForgedDuplicateAndExpiredKeys(t *testing.T) {
	now := time.Now()
	calls := 0
	backend := qaTestTransport(func(*http.Request) (*http.Response, error) { calls++; return nil, nil })
	for _, cookie := range []string{"", qaCookieName + "=invalid", qaCookieName + "=" + strings.Repeat("A", 43), qaTestCookie() + "; " + qaTestCookie()} {
		r := httptest.NewRequest("GET", "http://origin.invalid/test", nil)
		r.Header.Set("Cookie", cookie)
		w := httptest.NewRecorder()
		qaHandler(qaTestKey(), backend, now.Add(time.Minute), func() time.Time { return now }).ServeHTTP(w, r)
		if w.Code != 401 || w.Header().Get("X-HoneyObs-QA-Gate") == "" || w.Header().Get("Cache-Control") != "private, no-store" {
			t.Fatal("private denial missing")
		}
	}
	r := httptest.NewRequest("GET", "http://origin.invalid/test", nil)
	r.Header.Set("Cookie", qaTestCookie())
	w := httptest.NewRecorder()
	qaHandler(qaTestKey(), backend, now, func() time.Time { return now }).ServeHTTP(w, r)
	if w.Code != 401 || calls != 0 {
		t.Fatal("unauthorized request reached origin")
	}
}

func TestQAAuthenticationIsRemovedAndOriginIsFixed(t *testing.T) {
	seen := false
	backend := qaTestTransport(func(r *http.Request) (*http.Response, error) {
		seen = true
		if len(r.CookiesNamed(qaCookieName)) != 0 || r.Header.Get("Cookie") != "ordinary=value" || r.URL.Host != "honeyobs-qa-origin.invalid" || r.URL.Scheme != "http" || r.Host != "origin.invalid" || r.RequestURI != "" || !r.Close || r.Trailer != nil || r.Header.Get("Authorization") != "Bearer attack-canary" {
			t.Fatal("authentication or destination boundary changed")
		}
		return &http.Response{StatusCode: 404, Header: http.Header{"Cache-Control": []string{"public, max-age=3600"}, "Set-Cookie": []string{qaCookieName + "=overwrite; Path=/"}}, Body: io.NopCloser(strings.NewReader("not found"))}, nil
	})
	r := httptest.NewRequest("POST", "http://attacker.invalid/test?url=http://127.0.0.1/", strings.NewReader("body"))
	r.Host = "origin.invalid"
	r.Header.Add("Cookie", "ordinary=value")
	r.Header.Add("Cookie", qaTestCookie())
	r.Header.Set("Authorization", "Bearer attack-canary")
	r.Trailer = http.Header{"Cookie": []string{qaTestCookie()}}
	w := httptest.NewRecorder()
	qaHandler(qaTestKey(), backend, time.Now().Add(time.Minute), time.Now).ServeHTTP(w, r)
	if !seen || w.Code != 404 || w.Header().Get("Set-Cookie") != "" || w.Header().Get("Cache-Control") != "private, no-store" || w.Header().Get("Vary") != "Cookie" {
		t.Fatal("response exposed authentication or caching")
	}
}

func TestQAPipelineCannotForwardSecondAuthentication(t *testing.T) {
	var calls atomic.Int32
	backend := qaTestTransport(func(r *http.Request) (*http.Response, error) {
		calls.Add(1)
		if len(r.CookiesNamed(qaCookieName)) != 0 {
			t.Error("key forwarded")
		}
		return &http.Response{StatusCode: 404, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("not found"))}, nil
	})
	server := httptest.NewServer(qaHandler(qaTestKey(), backend, time.Now().Add(time.Minute), time.Now))
	defer server.Close()
	c, err := net.DialTimeout("tcp", server.Listener.Addr().String(), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	packet := "GET /test HTTP/1.1\r\nHost: origin.invalid\r\nCookie: " + qaTestCookie() + "\r\n\r\n"
	if _, err = io.WriteString(c, packet+packet); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(c)
	response, err := http.ReadResponse(reader, nil)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if _, err = http.ReadResponse(reader, nil); err == nil || calls.Load() != 1 {
		t.Fatal("pipelined authentication reached origin")
	}
}
