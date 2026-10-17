// Linux通信VM。外向きNICを持たず、固定用途のloopback→vsock中継だけを提供する。
package main

import (
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const afVsock = 40

type sockaddrVM struct {
	Family, Reserved uint16
	Port, CID        uint32
	Flags            uint8
	Zero             [3]byte
}

func vsock(port uint32) (net.Conn, error) {
	fd, e := syscall.Socket(afVsock, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if e != nil {
		return nil, e
	}
	a := sockaddrVM{Family: afVsock, Port: port, CID: 2}
	_, _, errno := syscall.Syscall(syscall.SYS_CONNECT, uintptr(fd), uintptr(unsafe.Pointer(&a)), unsafe.Sizeof(a))
	if errno != 0 {
		syscall.Close(fd)
		return nil, errno
	}
	syscall.SetNonblock(fd, true)
	return fileConn{os.NewFile(uintptr(fd), "egress-vsock")}, nil
}

type fileConn struct{ *os.File }
type vmAddr struct{}

func (vmAddr) Network() string          { return "vsock" }
func (vmAddr) String() string           { return "vsock" }
func (c fileConn) LocalAddr() net.Addr  { return vmAddr{} }
func (c fileConn) RemoteAddr() net.Addr { return vmAddr{} }
func (c fileConn) SetDeadline(t time.Time) error {
	if e := c.SetReadDeadline(t); e != nil {
		return e
	}
	return c.SetWriteDeadline(t)
}

type vmListener struct{ fd int }

func (l *vmListener) Accept() (net.Conn, error) {
	n, _, e := syscall.Syscall6(syscall.SYS_ACCEPT4, uintptr(l.fd), 0, 0, syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, 0, 0)
	if e != 0 {
		return nil, e
	}
	return fileConn{os.NewFile(n, "egress-health")}, nil
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
	if e := syscall.Listen(fd, 4); e != nil {
		syscall.Close(fd)
		return nil, e
	}
	return &vmListener{fd}, nil
}
func serveHealth(bridgePID, cloudflaredPID int) {
	l, e := listenVM(7003)
	if e != nil {
		log.Fatal(e)
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != "GET" || r.URL.Path != "/" || len(r.URL.Query().Get("nonce")) != 36 {
			http.Error(w, "invalid", 400)
			return
		}
		b, _ := os.ReadFile(fmt.Sprintf("/proc/%d/status", bridgePID))
		c, _ := os.ReadFile(fmt.Sprintf("/proc/%d/status", cloudflaredPID))
		alive := syscall.Kill(bridgePID, 0) == nil && syscall.Kill(cloudflaredPID, 0) == nil
		if !alive {
			w.WriteHeader(503)
		}
		json.NewEncoder(w).Encode(map[string]any{"nonce": r.URL.Query().Get("nonce"), "ready": alive, "bridgeStatus": string(b), "cloudflaredStatus": string(c), "networkDevices": 0, "sharedDirectories": 0, "storageDevices": 0})
	})
	server := &http.Server{Handler: handler, ReadHeaderTimeout: time.Second, ReadTimeout: time.Second, WriteTimeout: time.Second, IdleTimeout: time.Second, MaxHeaderBytes: 1024}
	log.Print(server.Serve(l))
}
func forward(local net.Conn, port uint32) {
	defer local.Close()
	remote, e := vsock(port)
	if e != nil {
		return
	}
	defer remote.Close()
	done := make(chan struct{}, 1)
	go func() { io.Copy(remote, local); done <- struct{}{} }()
	go func() { io.Copy(local, remote); done <- struct{}{} }()
	<-done
}
func bridge() {
	qaKey, err := bridgeQAKey(os.Getenv("QA_AUTH_REQUIRED"), os.Getenv("QA_ACCESS_KEY"))
	if err != nil {
		log.Fatal(err)
	}
	ports := []struct {
		local  string
		remote uint32
	}{{"127.0.0.1:7000", 9000}, {"127.0.0.1:7002", 9001}, {"127.0.0.1:7844", 9002}}
	if qaKey != nil {
		l, err := net.Listen("tcp4", "127.0.0.1:7000")
		if err != nil {
			log.Fatal("QA authentication listener unavailable")
		}
		go serveQA(l, qaKey)
		ports = ports[1:]
	}
	if os.Getenv("ALLOWED_MAIL") != "" {
		ports = append(ports, struct {
			local  string
			remote uint32
		}{"127.0.0.1:7003", 9003})
	}
	for _, p := range ports {
		l, e := net.Listen("tcp4", p.local)
		if e != nil {
			log.Fatal(e)
		}
		go func(l net.Listener, port uint32) {
			slots := make(chan struct{}, 8)
			for {
				c, e := l.Accept()
				if e != nil {
					return
				}
				select {
				case slots <- struct{}{}:
					go func() {
						defer func() { <-slots }()
						if port == 9003 {
							authProxy(c)
						} else {
							forward(c, port)
						}
					}()
				default:
					c.Close()
				}
			}
		}(l, p.remote)
	}
	fmt.Println("HONEYOBS_EGRESS_BRIDGE_READY")
	select {}
}
func noPrivileges() {
	// GoのgoroutineはOS thread間を移動する。NNPは全threadへ設定し、
	// 後続seccomp/execだけでなく別goroutineの隔離診断も同じ境界に置く。
	if _, _, e := syscall.AllThreadsSyscall6(syscall.SYS_PRCTL, 38, 1, 0, 0, 0, 0); e != 0 {
		log.Fatalf("prctl(PR_SET_NO_NEW_PRIVS): %v", e)
	}
	if _, _, e := syscall.Syscall6(syscall.SYS_PRCTL, 4, 0, 0, 0, 0, 0); e != 0 {
		log.Fatalf("prctl(PR_SET_DUMPABLE): %v", e)
	}
}
func status() map[string]any {
	st, _ := os.ReadFile("/proc/self/status")
	routes, _ := os.ReadFile("/proc/net/route")
	names := []string{}
	// net.Interfacesはnetlinkを開くため、seccomp後は読めるproc一覧を使う。
	devices, _ := os.ReadFile("/proc/net/dev")
	for _, line := range strings.Split(string(devices), "\n") {
		if colon := strings.IndexByte(line, ':'); colon >= 0 {
			names = append(names, strings.TrimSpace(line[:colon]))
		}
	}
	probes := map[string]string{}
	for _, target := range []string{"1.1.1.1:443", "192.168.1.1:80", "169.254.169.254:80", "[::1]:80", "[2606:4700:4700::1111]:443"} {
		c, e := net.DialTimeout("tcp", target, 100*time.Millisecond)
		if e == nil {
			c.Close()
			probes[target] = "CONNECTED"
		} else {
			probes[target] = e.Error()
		}
	}
	for _, domain := range []int{syscall.AF_PACKET, afVsock, syscall.AF_INET6} {
		fd, e := syscall.Socket(domain, syscall.SOCK_RAW, 0)
		if e == nil {
			syscall.Close(fd)
		}
		probes[fmt.Sprintf("socket-domain-%d", domain)] = fmt.Sprint(e)
	}
	fd, e := syscall.Socket(syscall.AF_INET, syscall.SOCK_RAW, syscall.IPPROTO_ICMP)
	if e == nil {
		syscall.Close(fd)
	}
	probes["raw-ipv4"] = fmt.Sprint(e)
	f, e := os.OpenFile("/write-probe", os.O_CREATE|os.O_WRONLY, 0600)
	if e == nil {
		f.Close()
	}
	probes["root-write"] = fmt.Sprint(e)
	probes["root-remount"] = fmt.Sprint(syscall.Mount("rootfs", "/", "", syscall.MS_REMOUNT, ""))
	fd, e = syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM, 0)
	if e == nil {
		var req [40]byte
		copy(req[:], "lo")
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), 0x8914, uintptr(unsafe.Pointer(&req[0])))
		probes["change-network"] = errno.Error()
		syscall.Close(fd)
	}
	// 正しい形式のTLSでも別SNIはホストの固定edge gateが拒否する。
	for _, serverName := range []string{"example.com", "h2.cftunnel.com.attacker.invalid"} {
		c, err := net.DialTimeout("tcp4", "127.0.0.1:7844", time.Second)
		if err == nil {
			c.SetDeadline(time.Now().Add(2 * time.Second))
			client := tls.Client(c, &tls.Config{ServerName: serverName, InsecureSkipVerify: true, MinVersion: tls.VersionTLS13})
			err = client.Handshake()
			c.Close()
		}
		probes["edge-sni-"+serverName] = fmt.Sprint(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, e = net.DefaultResolver.LookupHost(ctx, "example.invalid")
	probes["dns"] = fmt.Sprint(e)
	return map[string]any{"uid": os.Getuid(), "interfaces": names, "routes": string(routes), "processStatus": string(st), "probes": probes}
}

func cloudflared() {
	noPrivileges()
	if e := restrictSockets(); e != nil {
		log.Fatal(e)
	}
	b, _ := json.Marshal(status())
	fmt.Println("HONEYOBS_EGRESS_ISOLATION " + string(b))
	args, env, err := cloudflaredCommand(os.Getenv("ORIGIN_HOST"), os.Getenv("ALLOWED_MAIL"))
	if err != nil {
		log.Fatal(err)
	}
	if e := syscall.Exec("/cloudflared", args, env); e != nil {
		log.Fatalf("execve(/cloudflared): %v", e)
	}
}
func modules() {
	b, e := os.ReadFile("/modules/order")
	if e != nil {
		log.Fatal(e)
	}
	for _, name := range strings.Fields(string(b)) {
		b, e := os.ReadFile("/modules/" + name)
		if e != nil {
			log.Fatal(e)
		}
		p := []byte{0}
		_, _, n := syscall.Syscall(syscall.SYS_INIT_MODULE, uintptr(unsafe.Pointer(&b[0])), uintptr(len(b)), uintptr(unsafe.Pointer(&p[0])))
		if n != 0 {
			log.Fatal(n)
		}
	}
}
func loopback() {
	fd, e := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, 0)
	if e != nil {
		log.Fatal(e)
	}
	defer syscall.Close(fd)
	// ifreqはarm64 Linuxでも40 bytes。127/8はIFF_UPによりカーネルが設定する。
	var req [40]byte
	copy(req[:], "lo")
	req[16] = 0x49
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), 0x8914, uintptr(unsafe.Pointer(&req[0])))
	if errno != 0 {
		log.Fatal(errno)
	}
}
func initVM() {
	for _, m := range []struct{ s, d, t string }{{"proc", "/proc", "proc"}, {"sysfs", "/sys", "sysfs"}, {"devtmpfs", "/dev", "devtmpfs"}, {"tmpfs", "/tmp", "tmpfs"}} {
		os.MkdirAll(m.d, 0755)
		flags := uintptr(syscall.MS_NOSUID | syscall.MS_NODEV)
		if m.t == "devtmpfs" {
			flags = syscall.MS_NOSUID
		}
		if e := syscall.Mount(m.s, m.d, m.t, flags, ""); e != nil {
			log.Fatal(e)
		}
	}
	os.Chmod("/tmp", 0777)
	modules()
	loopback()
	// 追加NICがあってもIPv6を起動しない。現製品のVZ構成にもNICは存在しない。
	if e := os.WriteFile("/proc/sys/net/ipv6/conf/all/disable_ipv6", []byte("1"), 0600); e != nil && !os.IsNotExist(e) {
		log.Fatal(e)
	}
	cmd, _ := os.ReadFile("/proc/cmdline")
	origin := ""
	for _, s := range strings.Fields(string(cmd)) {
		if strings.HasPrefix(s, "honeyobs.host=") {
			origin = strings.TrimPrefix(s, "honeyobs.host=")
		}
	}
	if origin == "" {
		log.Fatal("origin missing")
	}
	recipient, err := privateRecipient(string(cmd))
	if err != nil {
		log.Fatal(err)
	}
	qaRequired, err := qaKeyRequired(string(cmd))
	if err != nil || (qaRequired && recipient != "") {
		log.Fatal("invalid QA authentication configuration")
	}
	var qaKey []byte
	if qaRequired {
		qaKey, err = readQAConsole()
		if err != nil {
			log.Fatal(err)
		}
	}
	if e := syscall.Mount("rootfs", "/", "", syscall.MS_REMOUNT|syscall.MS_RDONLY, ""); e != nil {
		log.Fatal(e)
	}
	start := func(mode string, uid uint32) *exec.Cmd {
		c := exec.Command("/init", mode)
		c.Env = []string{"ORIGIN_HOST=" + origin, "ALLOWED_MAIL=" + recipient}
		if mode == "bridge" && qaRequired {
			c.Env = append(c.Env, "QA_AUTH_REQUIRED=1", "QA_ACCESS_KEY="+base64.RawURLEncoding.EncodeToString(qaKey))
		}
		c.Stdout = os.Stdout
		c.Stderr = os.Stderr
		c.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uid, Gid: uid}}
		if e := c.Start(); e != nil {
			log.Fatal(e)
		}
		return c
	}
	b := start("bridge", 65534)
	// loopback受付の準備完了を確認してからcloudflaredを起動する。
	ready := false
	for i := 0; i < 100; i++ {
		c, e := net.DialTimeout("tcp4", "127.0.0.1:7000", 20*time.Millisecond)
		if e == nil {
			c.Close()
			ready = true
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if !ready {
		log.Fatal("bridge timeout")
	}
	if qaRequired {
		if err := verifyQABridge(origin, qaKey); err != nil {
			log.Fatal(err)
		}
	}
	c := start("cloudflared", 65533)
	go serveHealth(b.Process.Pid, c.Process.Pid)
	go func() { log.Print("bridge exited: ", b.Wait()); syscall.Kill(c.Process.Pid, syscall.SIGKILL) }()
	log.Print("cloudflared exited: ", c.Wait())
	syscall.Kill(b.Process.Pid, syscall.SIGKILL)
	for {
		syscall.Pause()
	}
}
func main() {
	log.SetFlags(0)
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "bridge":
			noPrivileges()
			bridge()
		case "cloudflared":
			cloudflared()
		case "probe":
			noPrivileges()
			if e := restrictSockets(); e != nil {
				log.Fatal(e)
			}
			json.NewEncoder(os.Stdout).Encode(status())
		}
		return
	}
	initVM()
}
