# benlevin.fyi

My personal site — [benlevin.fyi](https://benlevin.fyi) — served as a single
self-contained Go binary on a small VPS.

No framework, no build step, no CDN, no PaaS. `go build` produces one file with
every asset embedded in it; deployment is `scp` plus `systemctl restart`.

## Why it's built this way

A personal site is mostly a static page, and the usual answer is a JS framework
on someone else's hosting. This is the other end of that trade: the whole site
is one ~6 MB binary with no runtime dependencies, so there is nothing to install
on the server, nothing to keep in sync between a build directory and a web root,
and a rollback is putting the previous binary back.

What that buys, concretely:

- **Atomic deploys.** The binary *is* the site. There is no window where new
  HTML is live against old CSS.
- **No file-system surface.** Assets are read from `embed.FS`, not from disk, so
  path traversal and stale leftovers are not failure modes.
- **A health endpoint that isn't just the front page.** `/healthz` returns JSON
  from the application itself, so an uptime check distinguishes "the process is
  answering" from "nginx returned something".

## Layout

```
cmd/server/main.go          HTTP server: embedded FS, cache tiers, security headers
cmd/server/static/          index.html, css/, js/, assets/, robots.txt, sitemap.xml
deploy/benlevin-site.service  systemd unit (hardened: NoNewPrivileges, ProtectSystem)
deploy/benlevin.fyi.conf      nginx TLS vhost, reverse proxy to 127.0.0.1:8081
deploy/deploy.sh              build → upload → install → verify
```

## Implementation notes

**Cache-control is tiered by path**, because the three kinds of asset here have
very different lifetimes:

| Path | Policy | Reason |
|---|---|---|
| `/css/`, `/js/`, `/assets/` | `max-age=31536000, immutable` | Content-addressed in practice; a change ships a new binary |
| `/robots.txt`, `/sitemap.xml` | `max-age=86400` | Crawler-facing, changes rarely |
| everything else | `max-age=300, stale-while-revalidate=3600` | HTML should update quickly, but never block on revalidation |

**Shutdown is graceful and bounded.** `SIGTERM` drains in-flight requests for up
to 10 s, then forces exit — so a deploy can't hang systemd, and an in-flight
request isn't cut off mid-response.

**Security headers** (`X-Content-Type-Options`, `X-Frame-Options`,
`Referrer-Policy`, `X-XSS-Protection`) are set in the Go handler rather than in
nginx, so they hold if the site is ever served without the proxy in front.

**The page itself** inlines critical CSS, preloads the LCP portrait as a
responsive `<picture>` source set (WebP with JPEG fallback, 290w/560w), and
preloads the one webfont — so first paint doesn't wait on a network round trip.

## Running it

```bash
make run      # http://localhost:8081
make build    # ./bin/server
make test
```

## Deploying

Deployment targets are not in the repo. Copy the example and fill in your own:

```bash
cp deploy/deploy.env.example deploy/deploy.env   # gitignored
./deploy/deploy.sh
```

The script cross-compiles for `linux/amd64`, uploads the binary, installs the
systemd unit and nginx vhost, reloads both, and then verifies `/healthz` on the
server before reporting success.

## License

Code is MIT (see [LICENSE](LICENSE)). The site's written content and the
photographs of me are not — those are © Beniamin Levin, all rights reserved.
