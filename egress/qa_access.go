package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const qaCookieName = "__Host-HoneyObs-QA"
const qaLifetime = 10 * time.Minute

func qaKeyRequired(cmdline string) (bool, error) {
	count := 0
	for _, field := range strings.Fields(cmdline) {
		if strings.HasPrefix(field, "honeyobs.qaauth") {
			count++
			if field != "honeyobs.qaauth=1" {
				return false, errors.New("invalid QA authentication mode")
			}
		}
	}
	if count > 1 {
		return false, errors.New("duplicate QA authentication mode")
	}
	return count == 1, nil
}

func decodeQAKey(value string) ([]byte, error) {
	key, err := base64.RawURLEncoding.Strict().DecodeString(value)
	if err != nil || len(value) != 43 || len(key) != 32 {
		return nil, errors.New("invalid QA key")
	}
	return key, nil
}

// 鍵はカーネル引数へ入れない。echoを無効にした後にだけMacへ入力を要求する。
func readQAConsole() ([]byte, error) {
	f, err := os.OpenFile("/dev/console", os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, errors.New("QA console unavailable")
	}
	defer f.Close()
	var term syscall.Termios
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TCGETS, uintptr(unsafe.Pointer(&term)))
	if errno != 0 {
		return nil, errors.New("QA console attributes unavailable")
	}
	term.Lflag &^= syscall.ECHO | syscall.ECHONL
	_, _, errno = syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), syscall.TCSETS, uintptr(unsafe.Pointer(&term)))
	if errno != 0 {
		return nil, errors.New("QA console echo could not be disabled")
	}
	fmt.Println("HONEYOBS_QA_KEY_READY")
	line, err := bufio.NewReader(io.LimitReader(f, 65)).ReadString('\n')
	if err != nil || len(line) != 44 {
		return nil, errors.New("QA key input unavailable")
	}
	return decodeQAKey(strings.TrimSuffix(line, "\n"))
}

func bridgeQAKey(required, encoded string) ([]byte, error) {
	if required == "" && encoded == "" {
		return nil, nil
	}
	if required != "1" {
		return nil, errors.New("invalid QA bridge mode")
	}
	return decodeQAKey(encoded)
}

// 公開トンネルを作る前に、実際のbridgeが未認証を拒否することを確認する。
func verifyQABridge(origin string, key []byte) error {
	hash := sha256.Sum256(key)
	tag := hex.EncodeToString(hash[:])
	transport := &http.Transport{Proxy: nil, DisableKeepAlives: true}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 2 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	for _, cookie := range []string{"", qaCookieName + "=invalid"} {
		request, _ := http.NewRequest("GET", "http://127.0.0.1:7000/qa-auth-startup-proof", nil)
		request.Host = origin
		if cookie != "" {
			request.Header.Set("Cookie", cookie)
		}
		response, err := client.Do(request)
		if err != nil {
			return errors.New("QA authentication preflight unavailable")
		}
		_, err = io.Copy(io.Discard, io.LimitReader(response.Body, 1024))
		response.Body.Close()
		if err != nil || response.StatusCode != 401 || response.Header.Get("X-HoneyObs-QA-Gate") != tag {
			return errors.New("QA authentication preflight failed")
		}
	}
	fmt.Println("HONEYOBS_QA_BOUNDARY_VERIFIED")
	return nil
}

type qaAudit struct {
	mu         sync.Mutex
	ID         uint64 `json:"id"`
	Parsed     bool   `json:"parsed"`
	Authorized bool   `json:"authorized"`
	Proxied    bool   `json:"proxied"`
	Status     int    `json:"status"`
	PathSHA256 string `json:"pathSHA256,omitempty"`
	prefix     []byte
}
type qaAuditContext struct{}

var qaSequence atomic.Uint64

type qaConnection struct {
	net.Conn
	audit   *qaAudit
	once    sync.Once
	release func()
}

func (c *qaConnection) Write(p []byte) (int, error) {
	c.audit.mu.Lock()
	if len(c.audit.prefix) < 16 {
		c.audit.prefix = append(c.audit.prefix, p[:min(16-len(c.audit.prefix), len(p))]...)
		fields := bytes.Fields(c.audit.prefix)
		if len(fields) >= 2 && len(fields[1]) == 3 {
			c.audit.Status, _ = strconv.Atoi(string(fields[1]))
		}
	}
	c.audit.mu.Unlock()
	return c.Conn.Write(p)
}
func (c *qaConnection) Close() error {
	err := c.Conn.Close()
	c.once.Do(func() {
		c.release()
		c.audit.mu.Lock()
		defer c.audit.mu.Unlock()
		data, _ := json.Marshal(c.audit)
		log.Print("HONEYOBS_QA_INGRESS " + string(data))
	})
	return err
}

type qaListener struct {
	net.Listener
	slots chan struct{}
}

func (l *qaListener) Accept() (net.Conn, error) {
	for {
		c, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		select {
		case l.slots <- struct{}{}:
			return &qaConnection{Conn: c, audit: &qaAudit{ID: qaSequence.Add(1)}, release: func() { <-l.slots }}, nil
		default:
			c.Close()
			log.Print("HONEYOBS_QA_CAPACITY")
		}
	}
}

func qaHopHeader(name string) bool {
	switch strings.ToLower(name) {
	case "connection", "proxy-connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer", "transfer-encoding", "upgrade":
		return true
	}
	return false
}

func qaHandler(key []byte, transport http.RoundTripper, expires time.Time, now func() time.Time) http.Handler {
	tagBytes := sha256.Sum256(key)
	tag := hex.EncodeToString(tagBytes[:])
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.Close = true
		w.Header().Set("Connection", "close")
		w.Header().Set("Cache-Control", "private, no-store")
		w.Header().Set("Vary", "Cookie")
		w.Header().Set("X-HoneyObs-QA-Gate", tag)
		w.Header().Set("X-HoneyObs-QA-Stage", "authentication")
		audit, _ := r.Context().Value(qaAuditContext{}).(*qaAudit)
		if audit != nil {
			hash := sha256.Sum256([]byte(r.URL.RequestURI()))
			audit.mu.Lock()
			audit.Parsed = true
			audit.PathSHA256 = hex.EncodeToString(hash[:])
			audit.mu.Unlock()
		}
		matches := r.CookiesNamed(qaCookieName)
		var supplied []byte
		if len(matches) == 1 {
			supplied, _ = decodeQAKey(matches[0].Value)
		}
		if len(key) != 32 || !now().Before(expires) || len(matches) != 1 || !hmac.Equal(key, supplied) {
			w.Header().Set("WWW-Authenticate", `HoneyObs-QA realm="private test"`)
			http.Error(w, "Authentication required", http.StatusUnauthorized)
			return
		}
		if audit != nil {
			audit.mu.Lock()
			audit.Authorized = true
			audit.mu.Unlock()
		}
		request := r.Clone(r.Context())
		request.Header.Del("Cookie")
		for _, c := range r.Cookies() {
			if c.Name != qaCookieName {
				request.AddCookie(c)
			}
		}
		for name := range request.Header {
			if qaHopHeader(name) {
				request.Header.Del(name)
			}
		}
		request.Trailer = nil
		request.URL.Scheme = "http"
		request.URL.Host = "honeyobs-qa-origin.invalid"
		request.RequestURI = ""
		response, err := transport.RoundTrip(request)
		if err != nil {
			w.Header().Set("X-HoneyObs-QA-Stage", "transport")
			http.Error(w, "Upstream unavailable", 502)
			return
		}
		defer response.Body.Close()
		if audit != nil {
			audit.mu.Lock()
			audit.Proxied = true
			audit.mu.Unlock()
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 65537))
		if err != nil || len(body) > 65536 {
			w.Header().Set("X-HoneyObs-QA-Stage", "transport")
			http.Error(w, "Upstream unavailable", 502)
			return
		}
		for name, values := range response.Header {
			if qaHopHeader(name) || strings.EqualFold(name, "Cache-Control") || strings.EqualFold(name, "Vary") || strings.EqualFold(name, "Set-Cookie") || strings.HasPrefix(strings.ToLower(name), "x-honeyobs-qa-") {
				continue
			}
			for _, value := range values {
				w.Header().Add(name, value)
			}
		}
		for _, cookie := range response.Cookies() {
			if cookie.Name != qaCookieName {
				http.SetCookie(w, cookie)
			}
		}
		w.Header().Set("X-HoneyObs-QA-Stage", "origin")
		w.WriteHeader(response.StatusCode)
		_, _ = w.Write(body)
	})
}

func serveQA(l net.Listener, key []byte) {
	transport := &http.Transport{DisableKeepAlives: true, MaxConnsPerHost: 8, MaxResponseHeaderBytes: 8192, ResponseHeaderTimeout: 4 * time.Second,
		DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
			c, err := vsock(9000)
			if err == nil {
				err = c.SetDeadline(time.Now().Add(5 * time.Second))
				if err != nil {
					c.Close()
				}
			}
			return c, err
		}}
	server := &http.Server{Handler: qaHandler(key, transport, time.Now().Add(qaLifetime), time.Now),
		ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 6 * time.Second, IdleTimeout: time.Second, MaxHeaderBytes: 8192,
		ErrorLog: log.New(io.Discard, "", 0),
		ConnContext: func(ctx context.Context, c net.Conn) context.Context {
			return context.WithValue(ctx, qaAuditContext{}, c.(*qaConnection).audit)
		}}
	time.AfterFunc(qaLifetime, func() { log.Print("HONEYOBS_QA_EXPIRED"); os.Exit(1) })
	log.Print("HONEYOBS_QA_AUTH_READY")
	if err := server.Serve(&qaListener{Listener: l, slots: make(chan struct{}, 16)}); err != nil {
		log.Fatal("QA authentication listener stopped")
	}
}
