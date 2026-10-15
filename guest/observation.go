package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const eventCapacity = 4096
const pageSize = 128

type Event struct {
	ID            uint64 `json:"id"`
	Time          string `json:"time"`
	Method        string `json:"method"`
	Path          string `json:"path"`
	IP            string `json:"ip"`
	Status        int    `json:"status"`
	Test          bool   `json:"test"`
	PathBytes     int    `json:"pathBytes"`
	PathTruncated bool   `json:"pathTruncated"`
	PathSHA256    string `json:"pathSHA256,omitempty"`
}
type Rejection struct {
	Count    uint64 `json:"count"`
	LastTime string `json:"lastTime"`
}

var events struct {
	sync.Mutex
	Last       uint64
	Items      []Event
	Rejections map[string]Rejection
}
var boot = time.Now().UTC().Format(time.RFC3339Nano)

func record(r *http.Request, status int) {
	path := r.URL.EscapedPath()
	size := len(path)
	digest := ""
	if size > 512 {
		digest = fmt.Sprintf("%x", sha256.Sum256([]byte(path)))
		path = path[:512]
		// %エスケープの途中では切らない。
		if i := strings.LastIndexByte(path, '%'); i >= len(path)-2 {
			path = path[:i]
		}
	}
	ip := ""
	if parsed := net.ParseIP(r.Header.Get("Cf-Connecting-Ip")); parsed != nil {
		ip = parsed.String()
	}
	method := r.Method
	if len(method) > 32 {
		method = method[:32]
	}
	events.Lock()
	defer events.Unlock()
	events.Last++
	// 外来パスやヘッダーを信頼済みの内部確認として扱わない。
	events.Items = append(events.Items, Event{ID: events.Last, Time: time.Now().UTC().Format(time.RFC3339Nano), Method: method, Path: path, IP: ip, Status: status, Test: false, PathBytes: size, PathTruncated: size > 512, PathSHA256: digest})
	if len(events.Items) > eventCapacity {
		events.Items = events.Items[len(events.Items)-eventCapacity:]
	}
}
func reject(reason string) {
	events.Lock()
	defer events.Unlock()
	if events.Rejections == nil {
		events.Rejections = make(map[string]Rejection)
	}
	entry := events.Rejections[reason]
	entry.Count++
	entry.LastTime = time.Now().UTC().Format(time.RFC3339Nano)
	events.Rejections[reason] = entry
}
func snapshot(after uint64, uid int) map[string]any {
	events.Lock()
	defer events.Unlock()
	page := make([]Event, 0, pageSize)
	for _, event := range events.Items {
		if event.ID > after {
			page = append(page, event)
			if len(page) == pageSize {
				break
			}
		}
	}
	rejections := make(map[string]Rejection, len(events.Rejections))
	for k, v := range events.Rejections {
		rejections[k] = v
	}
	return map[string]any{"boot": boot, "uid": uid, "events": page, "total": events.Last, "rejections": rejections}
}

// HTTPパーサーより前で拒否された接続は、内容を保存せず理由別に集計する。
// Connection: closeの一要求接続。handler到達済みの要求はrecordとの二重計上を避ける。
type connectionKey struct{}
type observingConn struct {
	mu sync.Mutex
	net.Conn
	handled  bool
	received bool
	timedOut bool
	status   string
}

func (c *observingConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if n > 0 {
		c.mu.Lock()
		c.received = true
		c.mu.Unlock()
	}
	if timeout, ok := err.(net.Error); ok && timeout.Timeout() {
		c.mu.Lock()
		c.timedOut = true
		c.mu.Unlock()
	}
	return n, err
}
func (c *observingConn) Write(p []byte) (int, error) {
	c.mu.Lock()
	if c.status == "" && len(p) >= 12 && strings.HasPrefix(string(p[:9]), "HTTP/1.1 ") {
		c.status = string(p[9:12])
	}
	c.mu.Unlock()
	return c.Conn.Write(p)
}

type observingListener struct{ net.Listener }

func (l *observingListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &observingConn{Conn: c}, nil
}
func observationContext(ctx context.Context, c net.Conn) context.Context {
	return context.WithValue(ctx, connectionKey{}, c)
}
func observationState(conn net.Conn, state http.ConnState) {
	if state != http.StateClosed {
		return
	}
	c, ok := conn.(*observingConn)
	if !ok {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.handled || !c.received {
		return
	}
	reason := "http_incomplete"
	switch c.status {
	case "400":
		reason = "http_400"
	case "431":
		reason = "http_431"
	case "505":
		reason = "http_505"
	}
	if c.timedOut {
		reason = "http_timeout"
	}
	reject(reason)
}

func decoy(w http.ResponseWriter, r *http.Request) {
	if c, ok := r.Context().Value(connectionKey{}).(*observingConn); ok {
		c.mu.Lock()
		c.handled = true
		c.mu.Unlock()
	}
	w.Header().Set("Connection", "close")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	// Host値はトンネル起動時に上書きする。公開クライアントの任意値を許可しない。
	if r.Host != os.Getenv("ORIGIN_HOST") {
		record(r, 403)
		http.Error(w, "Forbidden", 403)
		return
	}
	if r.ContentLength > 8192 {
		record(r, 413)
		http.Error(w, "Request too large", 413)
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 8192)
	if _, err := io.Copy(io.Discard, r.Body); err != nil {
		record(r, 413)
		http.Error(w, "Request too large", 413)
		return
	}
	status := 404
	if r.URL.Path == "/login" {
		status = 401
	}
	record(r, status)
	w.WriteHeader(status)
	if status == 401 {
		io.WriteString(w, "Authentication failed\n")
	} else {
		io.WriteString(w, "Not found\n")
	}
}
