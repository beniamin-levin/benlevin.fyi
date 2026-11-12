package main

import (
	"bytes"
	"context"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// The CV is served from /cv.pdf. The public PDF on GitHub is the source of
// truth; a copy on the server's disk is the fallback for when GitHub is
// unreachable or the file is gone (e.g. the account is suspended). Every
// successful fetch refreshes that copy, and deploy.sh uploads it too.
const (
	cvSourceURL     = "https://raw.githubusercontent.com/beniamin-levin/beniamin-levin-cv-public/main/Beniamin-Levin-CV-public.pdf"
	cvDownloadName  = "Beniamin-Levin-CV.pdf"
	cvFreshFor      = 15 * time.Minute
	cvRetryAfter    = 5 * time.Minute
	cvFetchTimeout  = 4 * time.Second
	cvMaxSize       = 10 << 20
	cvDefaultOnDisk = "/opt/benlevin.fyi/cv/Beniamin-Levin-CV-public.pdf"
)

type cvCache struct {
	mu          sync.Mutex
	data        []byte
	modTime     time.Time
	fetchedAt   time.Time
	lastAttempt time.Time
	diskPath    string
	client      *http.Client
}

func newCVCache() *cvCache {
	p := os.Getenv("CV_FALLBACK_PATH")
	if p == "" {
		p = cvDefaultOnDisk
	}
	return &cvCache{diskPath: p, client: &http.Client{Timeout: cvFetchTimeout}}
}

// get returns the CV bytes and where they came from.
func (c *cvCache) get(ctx context.Context) ([]byte, time.Time, string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	if c.data != nil && now.Sub(c.fetchedAt) < cvFreshFor {
		return c.data, c.modTime, "github-cached"
	}
	if now.Sub(c.lastAttempt) >= cvRetryAfter {
		c.lastAttempt = now
		data, err := c.fetch(ctx)
		if err == nil {
			if !bytes.Equal(data, c.data) {
				c.modTime = now
			}
			c.data, c.fetchedAt = data, now
			c.saveToDisk(data)
			return c.data, c.modTime, "github"
		}
		log.Printf("cv: GitHub fetch failed, using fallback: %v", err)
	}
	if c.data != nil {
		return c.data, c.modTime, "github-stale"
	}
	if data, err := os.ReadFile(c.diskPath); err == nil && isPDF(data) {
		st, _ := os.Stat(c.diskPath)
		return data, st.ModTime(), "local"
	}
	return nil, time.Time{}, ""
}

func (c *cvCache) fetch(ctx context.Context) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, cvSourceURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, &cvError{"status " + resp.Status}
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, cvMaxSize+1))
	if err != nil {
		return nil, err
	}
	if len(data) > cvMaxSize || !isPDF(data) {
		return nil, &cvError{"response is not a PDF"}
	}
	return data, nil
}

func (c *cvCache) saveToDisk(data []byte) {
	if old, err := os.ReadFile(c.diskPath); err == nil && bytes.Equal(old, data) {
		return
	}
	if err := os.MkdirAll(filepath.Dir(c.diskPath), 0o755); err != nil {
		log.Printf("cv: cannot create fallback dir: %v", err)
		return
	}
	tmp := c.diskPath + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		log.Printf("cv: cannot write fallback copy: %v", err)
		return
	}
	if err := os.Rename(tmp, c.diskPath); err != nil {
		log.Printf("cv: cannot replace fallback copy: %v", err)
	}
}

func (c *cvCache) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	data, modTime, source := c.get(r.Context())
	if data == nil {
		http.Error(w, "CV temporarily unavailable", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/pdf")
	w.Header().Set("Content-Disposition", `attachment; filename="`+cvDownloadName+`"`)
	w.Header().Set("Cache-Control", "public, max-age=300")
	w.Header().Set("X-CV-Source", source)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, cvDownloadName, modTime, bytes.NewReader(data))
}

func isPDF(b []byte) bool { return bytes.HasPrefix(b, []byte("%PDF-")) }

type cvError struct{ msg string }

func (e *cvError) Error() string { return e.msg }
