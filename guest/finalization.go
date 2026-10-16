package main

import (
	"context"
	"net/http"
	"sync"
	"time"
)

// 最後のページを読む前に入口と全接続の観測を閉じる。時間切れを完全取得と扱わない。
type observationFinalizer struct {
	once     sync.Once
	done     chan struct{}
	complete bool
	server   *http.Server
}

var decoyFinalizer = observationFinalizer{done: make(chan struct{})}
var observationConnections sync.WaitGroup

func (f *observationFinalizer) finalize() bool {
	f.once.Do(func() {
		go func() {
			defer close(f.done)
			if f.server == nil {
				return
			}
			ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
			defer cancel()
			if f.server.Shutdown(ctx) != nil {
				return
			}
			// Shutdownの接続管理とConnStateフックの完了を別々に待つ。
			closed := make(chan struct{})
			go func() { observationConnections.Wait(); close(closed) }()
			select {
			case <-closed:
				f.complete = true
			case <-ctx.Done():
			}
		}()
	})
	select {
	case <-f.done:
		return f.complete
	case <-time.After(225 * time.Millisecond):
		return false
	}
}
