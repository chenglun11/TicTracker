package main

import (
	"sync"
	"time"
)

type authFailureWindow struct {
	count     int
	startedAt time.Time
}

type authFailureLimiter struct {
	mu       sync.Mutex
	limit    int
	window   time.Duration
	failures map[string]authFailureWindow
}

func newAuthFailureLimiter(limit int, window time.Duration) *authFailureLimiter {
	return &authFailureLimiter{limit: limit, window: window, failures: make(map[string]authFailureWindow)}
}

func (l *authFailureLimiter) allow(key string, now time.Time) (bool, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry, exists := l.failures[key]
	if !exists || now.Sub(entry.startedAt) >= l.window {
		delete(l.failures, key)
		return true, 0
	}
	if entry.count < l.limit {
		return true, 0
	}
	retryAfter := l.window - now.Sub(entry.startedAt)
	if retryAfter < time.Second {
		retryAfter = time.Second
	}
	return false, retryAfter
}

func (l *authFailureLimiter) failed(key string, now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	entry, exists := l.failures[key]
	if !exists || now.Sub(entry.startedAt) >= l.window {
		entry = authFailureWindow{startedAt: now}
	}
	entry.count++
	l.failures[key] = entry
}

func (l *authFailureLimiter) reset(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	delete(l.failures, key)
}

var webLoginFailures = newAuthFailureLimiter(10, 15*time.Minute)
