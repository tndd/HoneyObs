//go:build linux

package main

import (
	"os"
	"syscall"
	"testing"
	"time"
)

func TestRawListenerCloseWakesAccept(t *testing.T) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC|syscall.SOCK_NONBLOCK, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err = syscall.Bind(fd, &syscall.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}); err != nil {
		syscall.Close(fd)
		t.Fatal(err)
	}
	if err = syscall.Listen(fd, 1); err != nil {
		syscall.Close(fd)
		t.Fatal(err)
	}
	file := os.NewFile(uintptr(fd), "listener")
	raw, err := file.SyscallConn()
	if err != nil {
		file.Close()
		t.Fatal(err)
	}
	listener := &vmListener{file: file, raw: raw}
	finished := make(chan error, 1)
	go func() { _, err := listener.Accept(); finished <- err }()
	time.Sleep(10 * time.Millisecond)
	if err = listener.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-finished:
		if err == nil {
			t.Fatal("close済みlistenerが接続を返した")
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("accept待機が解除されなかった")
	}
}
