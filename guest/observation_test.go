package main

import (
	"bufio"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
	"time"
)

func resetObservations() {
	events.Lock()
	defer events.Unlock()
	events.Last = 0
	events.Items = nil
	events.Rejections = nil
}
func TestBoundedPagesAndUntrustedMarker(t *testing.T) {
	resetObservations()
	for i := 0; i < 5000; i++ {
		r, _ := http.NewRequest("GET", "http://local/honeyobs-test-attacker", nil)
		record(r, 404)
	}
	p := snapshot(0, 65534)
	list := p["events"].([]Event)
	if len(list) != 128 || list[0].ID != 905 || list[0].Test {
		t.Fatal("容量・欠落ID・外来マーカーの扱いが不正", list[0])
	}
	if len(events.Items) != 4096 {
		t.Fatal("保持上限超過")
	}
	next := snapshot(list[127].ID, 65534)["events"].([]Event)
	if next[0].ID != list[127].ID+1 {
		t.Fatal("ページ間の重複または欠落")
	}
}
func TestPathIdentityAndPrivacy(t *testing.T) {
	resetObservations()
	for _, end := range []string{"A", "B"} {
		r, _ := http.NewRequest("POST", "http://local/"+strings.Repeat("a", 520)+end+"?password=SECRET", strings.NewReader("SECRET"))
		r.Header.Set("Authorization", "SECRET")
		record(r, 401)
	}
	a, b := events.Items[0], events.Items[1]
	if a.Path != b.Path || a.PathBytes != 522 || !a.PathTruncated || a.PathSHA256 == b.PathSHA256 || len(a.PathSHA256) != 64 {
		t.Fatal("切り詰めの識別情報が不正")
	}
	raw, _ := json.Marshal(snapshot(0, 65534))
	if strings.Contains(string(raw), "SECRET") {
		t.Fatal("秘密情報を保存した")
	}
	r, _ := http.NewRequest("GET", "http://local/"+strings.Repeat("a", 509)+"%20tail", nil)
	record(r, 404)
	if strings.HasSuffix(events.Items[2].Path, "%2") {
		t.Fatal("エスケープ途中で切断した")
	}
}
func TestRejectedHTTPAndHost(t *testing.T) {
	resetObservations()
	t.Setenv("ORIGIN_HOST", "expected.invalid")
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &http.Server{Handler: http.HandlerFunc(decoy), ConnContext: observationContext, ConnState: observationState, ReadHeaderTimeout: 100 * time.Millisecond, MaxHeaderBytes: 4096}
	go server.Serve(&observingListener{Listener: listener})
	defer server.Close()
	tests := []struct{ request, status string }{
		{"GET / HTTP/1.1\r\nHost: wrong.invalid\r\n\r\n", "403"},
		{"G(ET / HTTP/1.1\r\nHost: expected.invalid\r\n\r\n", "400"},
		{"POST / HTTP/1.1\r\nHost: expected.invalid\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nxx", "400"},
		{"GET / HTTP/1.1\r\nHost: expected.invalid\r\nX-Big: " + strings.Repeat("x", 10000) + "\r\n\r\n", "431"},
	}
	for _, test := range tests {
		c, e := net.Dial("tcp", listener.Addr().String())
		if e != nil {
			t.Fatal(e)
		}
		c.SetDeadline(time.Now().Add(2 * time.Second))
		io.WriteString(c, test.request)
		line, _ := bufio.NewReader(c).ReadString('\n')
		c.Close()
		if !strings.Contains(line, test.status) {
			t.Fatal(line)
		}
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		events.Lock()
		ok := events.Rejections["http_400"].Count == 2 && events.Rejections["http_431"].Count == 1 && len(events.Items) == 1 && events.Items[0].Status == 403
		events.Unlock()
		if ok {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("拒否が記録されていない", snapshot(0, 65534))
}
