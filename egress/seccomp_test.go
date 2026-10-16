//go:build linux && arm64

package main

import (
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"testing"
)

// このtest binaryだけをNIC/共有/ディスクなしの私有VMでPID1として実行する。
func TestMain(m *testing.M) {
	if os.Getpid() != 1 {
		os.Exit(m.Run())
	}
	if err := syscall.Mount("devtmpfs", "/dev", "devtmpfs", syscall.MS_NOSUID, ""); err != nil {
		fmt.Println("HONEYOBS_PRIVILEGES_FAIL devtmpfs:", err)
		for {
			syscall.Pause()
		}
	}
	if err := syscall.Mount("proc", "/proc", "proc", 0, ""); err != nil {
		fmt.Println("HONEYOBS_PRIVILEGES_FAIL mount:", err)
	} else if m.Run() == 0 {
		fmt.Println("HONEYOBS_PRIVILEGES_PASS")
	} else {
		fmt.Println("HONEYOBS_PRIVILEGES_FAIL tests")
	}
	for {
		syscall.Pause()
	}
}

func boundary(t *testing.T) {
	t.Helper()
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	b, err := os.ReadFile("/proc/thread-self/status")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"NoNewPrivs:\t1", "Seccomp:\t2", "Uid:\t65533\t65533\t65533\t65533", "CapEff:\t0000000000000000"} {
		if !strings.Contains(string(b), want) {
			t.Fatalf("thread %d missing %q: %s", syscall.Gettid(), want, b)
		}
	}
	fd, err := syscall.Socket(syscall.AF_INET6, syscall.SOCK_STREAM, 0)
	if err == nil {
		syscall.Close(fd)
		t.Fatal("IPv6 socket escaped filter")
	}
	if err != syscall.EPERM {
		t.Fatalf("IPv6 socket: %v", err)
	}
}

func TestSandboxThreads(t *testing.T) {
	if os.Getenv("HONEYOBS_SANDBOX_CHILD") == "" {
		if os.Getuid() != 0 {
			t.Skip("isolated Linux VM root launcher required")
		}
		exe, _ := os.Executable()
		cmd := exec.Command(exe, "-test.run=^TestSandboxThreads$", "-test.v")
		cmd.Env = []string{"HONEYOBS_SANDBOX_CHILD=install"}
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: 65533, Gid: 65533}}
		if b, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("unprivileged child: %v\n%s", err, b)
		} else {
			t.Log(string(b))
		}
		return
	}
	if os.Getenv("HONEYOBS_SANDBOX_CHILD") == "inherited" {
		boundary(t)
		var wg sync.WaitGroup
		for i := 0; i < 16; i++ {
			wg.Add(1)
			go func() { defer wg.Done(); boundary(t) }()
		}
		wg.Wait()
		return
	}
	// no_new_privs設定threadを保持し、必ず別threadでseccompを設定する。
	// 旧実装はここでEACCES。負荷や偶然のscheduler移動に依存しない。
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	checkExisting, releaseExisting := make(chan struct{}), make(chan struct{})
	var existingReady, existingChecked sync.WaitGroup
	for i := 0; i < 8; i++ {
		existingReady.Add(1)
		existingChecked.Add(1)
		go func() {
			runtime.LockOSThread()
			defer runtime.UnlockOSThread()
			existingReady.Done()
			<-checkExisting
			func() { defer existingChecked.Done(); boundary(t) }()
			<-releaseExisting
		}()
	}
	existingReady.Wait()
	defer close(releaseExisting)
	ready, release := make(chan struct{}), make(chan struct{})
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		noPrivileges()
		close(ready)
		<-release
	}()
	<-ready
	defer close(release)
	if err := restrictSockets(); err != nil {
		t.Fatalf("seccomp on a different Go thread: %v", err)
	}
	boundary(t)
	close(checkExisting)
	existingChecked.Wait()
	var wg sync.WaitGroup
	for i := 0; i < 32; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); boundary(t) }()
	}
	wg.Wait()
	exe, _ := os.Executable()
	cmd := exec.Command(exe, "-test.run=^TestSandboxThreads$", "-test.v")
	cmd.Env = []string{"HONEYOBS_SANDBOX_CHILD=inherited"}
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("exec inheritance: %v\n%s", err, b)
	}
	t.Log("8 existing locked threads, 32 new goroutines, and 16 exec-child goroutines confined")
}
