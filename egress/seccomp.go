package main

import (
	"fmt"
	"syscall"
	"unsafe"
)

// cloudflared自身はIPv4 TCPだけを作れる。vsockは別UIDの固定中継だけが保持する。
// io_uringによるsocket syscallの迂回も禁止し、アーキテクチャ不一致は強制終了する。
func restrictSockets() error {
	type filter struct {
		Code   uint16
		JT, JF uint8
		K      uint32
	}
	const load = 0x20
	const equal = 0x15
	const ret = 0x06
	const deny = 0x00050001
	const allow = 0x7fff0000
	filters := []filter{{load, 0, 0, 4}, {equal, 1, 0, 0xc00000b7}, {ret, 0, 0, 0x80000000}, {load, 0, 0, 0}}
	// arm64の危険な管理syscall。UID境界に加えて明示的に拒否する。
	for _, nr := range []uint32{syscall.SYS_MOUNT, syscall.SYS_UMOUNT2, syscall.SYS_PTRACE, syscall.SYS_INIT_MODULE, syscall.SYS_DELETE_MODULE, syscall.SYS_UNSHARE, syscall.SYS_SETNS, syscall.SYS_REBOOT, 280, 281, 282, 425, 426, 427} {
		filters = append(filters, filter{equal, 0, 1, nr}, filter{ret, 0, 0, deny})
	}
	// socket(domain,type,protocol): AF_INET + SOCK_STREAM (フラグ除去後)のみ。
	filters = append(filters, filter{equal, 0, 7, uint32(syscall.SYS_SOCKET)}, filter{load, 0, 0, 16}, filter{equal, 0, 4, syscall.AF_INET}, filter{load, 0, 0, 24}, filter{0x54, 0, 0, 0xf}, filter{equal, 0, 1, syscall.SOCK_STREAM}, filter{ret, 0, 0, allow}, filter{ret, 0, 0, deny}, filter{ret, 0, 0, allow})
	prog := struct {
		Len    uint16
		Filter *filter
	}{uint16(len(filters)), &filters[0]}
	// NNPと同様に既存の全Go runtime threadへ同期する。新threadとexecも
	// このfilterを継承するので、socket処理のgoroutine移動に依存しない。
	const setModeFilter, syncThreads = 1, 1
	r, _, e := syscall.Syscall(syscall.SYS_SECCOMP, setModeFilter, syncThreads, uintptr(unsafe.Pointer(&prog)))
	if e != 0 {
		return fmt.Errorf("seccomp(SECCOMP_SET_MODE_FILTER, TSYNC): %w", e)
	}
	if r != 0 {
		return fmt.Errorf("seccomp(TSYNC): thread %d did not synchronize", r)
	}
	return nil
}
