// Linux VMのPID 1と、権限を落とした模擬HTTPサービス。
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const afVsock = 40

type sockaddrVM struct {
	Family   uint16
	Reserved uint16
	Port     uint32
	CID      uint32
	Flags    uint8
	Zero     [3]byte
}
type vmAddr struct{}

func (vmAddr) Network() string { return "vsock" }
func (vmAddr) String() string  { return "vsock" }

type vmConn struct{ *os.File }

func (c vmConn) LocalAddr() net.Addr  { return vmAddr{} }
func (c vmConn) RemoteAddr() net.Addr { return vmAddr{} }
func (c vmConn) SetDeadline(t time.Time) error {
	if err := c.SetReadDeadline(t); err != nil {
		return err
	}
	return c.SetWriteDeadline(t)
}

type vmListener struct{ fd int }

func (l *vmListener) Accept() (net.Conn, error) {
	// Goのsyscall.AcceptはAF_VSOCKを変換できないため、アドレスなしでaccept4する。
	n, _, e := syscall.Syscall6(syscall.SYS_ACCEPT4, uintptr(l.fd), 0, 0, syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, 0, 0)
	if e != 0 {
		return nil, e
	}
	return vmConn{os.NewFile(n, "vsock")}, nil
}
func (l *vmListener) Close() error   { return syscall.Close(l.fd) }
func (l *vmListener) Addr() net.Addr { return vmAddr{} }
func listenVM(port uint32) (*vmListener, error) {
	fd, e := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if e != nil {
		return nil, e
	}
	a := sockaddrVM{Family: afVsock, Port: port, CID: 0xffffffff}
	_, _, errno := syscall.Syscall(syscall.SYS_BIND, uintptr(fd), uintptr(unsafe.Pointer(&a)), unsafe.Sizeof(a))
	if errno != 0 {
		syscall.Close(fd)
		return nil, errno
	}
	if e = syscall.Listen(fd, 16); e != nil {
		syscall.Close(fd)
		return nil, e
	}
	return &vmListener{fd}, nil
}

type Event struct {
	ID     uint64 `json:"id"`
	Time   string `json:"time"`
	Method string `json:"method"`
	Path   string `json:"path"`
	IP     string `json:"ip"`
	Status int    `json:"status"`
	Test   bool   `json:"test"`
}

var events struct {
	sync.Mutex
	Last  uint64
	Items []Event
}
var boot = time.Now().UTC().Format(time.RFC3339Nano)

func record(r *http.Request, status int) {
	path := r.URL.EscapedPath()
	if len(path) > 512 {
		path = path[:512]
	}
	ip := ""
	if parsed := net.ParseIP(r.Header.Get("Cf-Connecting-Ip")); parsed != nil {
		ip = parsed.String()
	}
	events.Lock()
	defer events.Unlock()
	events.Last++
	events.Items = append(events.Items, Event{events.Last, time.Now().UTC().Format(time.RFC3339Nano), r.Method, path, ip, status, strings.HasPrefix(path, "/honeyobs-test-")})
	if len(events.Items) > 128 {
		events.Items = events.Items[len(events.Items)-128:]
	}
}

func decoy(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Connection", "close")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	// Host値はトンネル起動時に上書きする。公開クライアントの任意値を許可しない。
	if r.Host != os.Getenv("ORIGIN_HOST") {
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

func isolation(targets []string) map[string]any {
	ifaces, _ := net.Interfaces()
	names := []string{}
	for _, v := range ifaces {
		names = append(names, v.Name)
	}
	probes := map[string]string{}
	for _, target := range targets {
		host, _, err := net.SplitHostPort(target)
		if err != nil || net.ParseIP(host) == nil {
			continue
		}
		c, err := net.DialTimeout("tcp", target, 400*time.Millisecond)
		if err == nil {
			probes[target] = "CONNECTED"
			c.Close()
		} else {
			probes[target] = err.Error()
		}
	}
	for _, port := range []uint32{7000, 7001, 12345} {
		fd, err := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK, 0)
		if err != nil {
			probes[fmt.Sprintf("host-vsock:%d", port)] = err.Error()
			continue
		}
		a := sockaddrVM{Family: afVsock, Port: port, CID: 2}
		_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&a)), unsafe.Sizeof(a))
		if errno == syscall.EINPROGRESS {
			time.Sleep(100 * time.Millisecond)
			v, _ := syscall.GetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_ERROR)
			errno = syscall.Errno(v)
		}
		if errno == 0 {
			probes[fmt.Sprintf("host-vsock:%d", port)] = "CONNECTED"
		} else {
			probes[fmt.Sprintf("host-vsock:%d", port)] = errno.Error()
		}
		syscall.Close(fd)
	}
	_, writeErr := os.OpenFile("/system-write-probe", os.O_WRONLY|os.O_CREATE, 0600)
	writeResult := "WRITABLE"
	if writeErr != nil {
		writeResult = writeErr.Error()
	}
	routes, routeErr := os.ReadFile("/proc/net/route")
	mounts, mountErr := os.ReadFile("/proc/mounts")
	return map[string]any{"uid": os.Getuid(), "interfaces": names, "probes": probes, "rootWrite": writeResult, "routes": string(routes), "routeReadError": fmt.Sprint(routeErr), "mounts": string(mounts), "mountReadError": fmt.Sprint(mountErr)}
}

func control(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Connection", "close")
	if r.URL.Path == "/isolation" {
		targets := []string{"1.1.1.1:443", "192.168.1.1:80", "127.0.0.1:80"}
		for _, v := range r.URL.Query()["target"] {
			if len(targets) < 8 {
				targets = append(targets, v)
			}
		}
		json.NewEncoder(w).Encode(isolation(targets))
		return
	}
	events.Lock()
	defer events.Unlock()
	json.NewEncoder(w).Encode(map[string]any{"boot": boot, "uid": os.Getuid(), "events": events.Items, "total": events.Last})
}

func serve() {
	for _, v := range []struct {
		port    uint32
		handler http.HandlerFunc
	}{{7000, decoy}, {7001, control}} {
		l, err := listenVM(v.port)
		if err != nil {
			log.Fatal(err)
		}
		s := &http.Server{Handler: v.handler, ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 4 * time.Second, WriteTimeout: 4 * time.Second, IdleTimeout: time.Second, MaxHeaderBytes: 4096}
		go func() { log.Fatal(s.Serve(l)) }()
	}
	fmt.Println("HONEYOBS_READY uid=", os.Getuid())
	select {}
}

func initVM() {
	for _, d := range []string{"/proc", "/sys", "/dev", "/tmp"} {
		os.MkdirAll(d, 0755)
	}
	for _, m := range []struct{ src, dst, typ string }{{"proc", "/proc", "proc"}, {"sysfs", "/sys", "sysfs"}, {"devtmpfs", "/dev", "devtmpfs"}, {"tmpfs", "/tmp", "tmpfs"}} {
		flags := uintptr(syscall.MS_NOSUID | syscall.MS_NODEV)
		if m.typ == "devtmpfs" {
			flags = syscall.MS_NOSUID
		}
		if err := syscall.Mount(m.src, m.dst, m.typ, flags, ""); err != nil {
			log.Fatal(err)
		}
	}
	os.Chmod("/tmp", 0777)
	order, err := os.ReadFile("/modules/order")
	if err != nil {
		log.Fatal(err)
	}
	for _, name := range strings.Fields(string(order)) {
		data, err := os.ReadFile("/modules/" + name)
		if err != nil {
			log.Fatal(err)
		}
		params := []byte{0}
		_, _, errno := syscall.Syscall(syscall.SYS_INIT_MODULE, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)), uintptr(unsafe.Pointer(&params[0])))
		if errno != 0 {
			log.Fatalf("module %s: %v", name, errno)
		}
	}
	// 起動時の指定値はアプリが生成し、公開要求からは変更できない。
	cmdline, _ := os.ReadFile("/proc/cmdline")
	origin := ""
	for _, v := range strings.Fields(string(cmdline)) {
		if strings.HasPrefix(v, "honeyobs.host=") {
			origin = strings.TrimPrefix(v, "honeyobs.host=")
		}
	}
	if origin == "" {
		log.Fatal("origin missing")
	}
	if err = syscall.Mount("rootfs", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, ""); err != nil {
		log.Fatalf("root readonly: %v", err)
	}
	child := exec.Command("/init", "serve")
	child.Env = []string{"ORIGIN_HOST=" + origin}
	child.Stdout = os.Stdout
	child.Stderr = os.Stderr
	child.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 65534, Gid: 65534}}
	if err := child.Run(); err != nil {
		log.Print(err)
	}
	for {
		syscall.Pause()
	}
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "serve" {
		// 再実行後の権限昇格を禁止する。
		_, _, e := syscall.Syscall6(syscall.SYS_PRCTL, 38, 1, 0, 0, 0, 0)
		if e != 0 {
			log.Fatal(e)
		}
		serve()
		return
	}
	initVM()
}
