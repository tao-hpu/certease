# certease

[English](README.md) | [中文](README.zh.md)

Standardized ACME orchestration for heterogeneous Linux fleets.

A thin, idempotent Bash layer above `acme.sh` and `certbot` that unifies SSL rotation across machines with divergent nginx layouts (vanilla, LNMP one-click, control panels). Auto-detects environment, installs a consistent cron, wires a validated reload hook, and surfaces state through a single `doctor` command.

---

## When to use this

certease is designed for operators in the following situation:

- Several Linux servers, each running ACME-based SSL rotation through `acme.sh` (optionally mixed with `certbot`).
- The servers are heterogeneous: different nginx installation sources (distribution package, LNMP one-click, control panel), different webroots, different reload commands.
- You have attempted to write the rotation setup yourself, or asked an AI assistant to do so, and found that each machine ends up with subtly different config, cron expressions, hook paths, and failure modes.
- You want a single command that brings any new or inherited machine into a known-good state, and a single command to check fleet health.

certease is **not** the right tool if:

- Your workloads run on Docker or Kubernetes. Use Caddy or cert-manager.
- You are on managed cloud certificates (AWS ACM, Cloudflare SSL). No origin rotation is needed.
- You operate a single host with a standard layout. Plain `certbot` with its systemd timer is sufficient.

## What it does

| Command | Purpose |
|---|---|
| `bash install.sh` | Detect environment, write config, install cron, wire reload hooks. Idempotent. |
| `certease status` | One-line per certificate: tool, CA, expiry, days remaining. |
| `certease doctor` | Full health check: cron, logging, hook wiring, nginx syntax, orphan directories, CA account email. |
| `certease renew [domain]` | Manual renewal with automatic CA fallback (ZeroSSL → Let's Encrypt). |

## What it does not do

- Replace `acme.sh` or `certbot`. They remain the certificate issuers. certease is an orchestration layer.
- Manage DNS-01 challenges. Use the native DNS plugins shipped with `acme.sh`.
- Touch certificate contents. Issuance, validation, and key management are delegated to the underlying tool.
- Proxy, cache, or terminate TLS. Deployment to nginx is via a reload hook only.

## Key design points

**Nginx flavor auto-detection.** Three supported flavors with distinct paths:

| Flavor | nginx binary | SSL deploy directory | Detection signal |
|---|---|---|---|
| `std` | `/usr/sbin/nginx` | `/etc/nginx/ssl/` | Distribution package install |
| `lnmp` | `/usr/local/nginx/sbin/nginx` | `/usr/local/nginx/conf/ssl/` | LNMP one-click script |
| `bt` | `/www/server/nginx/sbin/nginx` | `/www/server/panel/vhost/cert/<server_name>/` | Presence of `/www/server/panel/` |

**Fallback CA.** When the primary CA returns a rate-limit or validation error, `certease renew` retries against a secondary CA. The default configuration signs with ZeroSSL and falls back to Let's Encrypt. Configured via `FALLBACK_CA` in `/etc/certease.conf`.

**Validated reload.** The deploy hook (`hooks/reload-cert.sh`) copies the new certificate, runs `nginx -t` before reload, and emits structured log lines for every deploy event. Failed syntax checks abort the reload without touching the live certificate chain.

**Idempotent install.** Re-running `install.sh` is safe. It will not duplicate cron entries, overwrite `/etc/certease.conf`, or modify a correct `Le_ReloadCmd`.

**No runtime dependencies.** Pure Bash. No Python, Node, Go, or Ruby.

## Quick start

```bash
git clone https://github.com/tao-hpu/certease.git /root/certease
cd /root/certease
bash install.sh
certease doctor
```

Per-host configuration lives in `/etc/certease.conf`:

```sh
ACCOUNT_EMAIL=you@example.com
FALLBACK_CA=letsencrypt    # empty to disable fallback
```

## Why this exists

A common pattern: four or five servers behind your infrastructure, each running ACME rotation through `acme.sh`, each provisioned months or years apart on top of different nginx installations. One uses the distro package. One uses an LNMP one-click script. Two sit behind a control panel with its own nginx layout. One uses certbot with a systemd timer.

When a certificate fails to renew or a new machine needs to join the fleet, the recovery process reads roughly the same every time:

1. Locate where `acme.sh` actually lives on this host.
2. Identify the nginx binary and configuration root for this particular flavor.
3. Determine the webroot the existing vhosts are using.
4. Verify that a cron entry exists, that it logs somewhere, that the hook points at a path that still exists.
5. Re-derive the reload command, test nginx syntax, reissue.

Asked to write this setup in a new session, an AI assistant produces output that is never byte-for-byte identical to the previous time. One version invokes `/root/.acme.sh/acme.sh --cron`. The next uses `--install-cronjob`. One writes to `/var/log/letsencrypt.log`. The next logs nowhere. Hook paths drift. Error-handling branches diverge. The resulting scripts work on the day they are written and break in different ways six months later.

The cost is not the time to author one script. It is the **compounding divergence across the fleet**. Every ad-hoc rewrite is a new snowflake, and the next failure requires re-learning a slightly different configuration.

certease fixes the shape: the environment detection, cron expression, hook contract, and observability surface are identical on every host. `certease doctor` output structure holds across flavors. `install.sh` handles the three nginx layouts without operator-side branching. Environment-specific knowledge that used to live in tribal memory — "on the BT server you resolve the cert directory by `server_name`, not `Le_Domain`" — is encoded once in `lib/nginx_flavors.sh`.

## Troubleshooting

**`certease renew` succeeds but nginx still serves the old certificate.**
`acme.sh --issue --force` issues but does not redeploy. Run `certease renew`, which triggers the reload hook, or invoke `acme.sh --install-cert -d <domain> ...` explicitly.

**Cert directory under the BT panel has an unexpected name.**
BT names the deploy directory by the vhost's first `server_name` entry, not the `Le_Domain` field from `acme.sh`. certease's `bt_resolve_cert_dir()` handles this. If a vhost was renamed after issuance, rerun `bash install.sh` to rewire the hook.

**HTTP-01 challenge returns 404 on a redirecting vhost.**
An unconditional `return 301 https://...` at the server level runs before `location` matching. Wrap the redirect inside `location / { ... }` so that `location ^~ /.well-known/acme-challenge/ { ... }` can take precedence.

**`git clone` redirects to an unreachable proxy.**
Some hosts carry a global `.gitconfig` pointing at an internal HTTP proxy. Override per-invocation:
```bash
git -c http.proxy= -c https.proxy= clone https://github.com/tao-hpu/certease.git
```

**`certbot update_account --email` appears to succeed but `doctor` still reports no email.**
certbot does not always write the updated contact back to the local `regr.json`. The ACME server state may be current; the local check reads a cache that the CLI did not refresh.

## Repository layout

```
bin/certease              CLI entry point
lib/
  detect.sh               Environment and flavor detection
  nginx_flavors.sh        Per-flavor paths and reload commands
  install_cron.sh         Cron installation and logging setup
  install_hook.sh         acme.sh reload hook wiring
  status.sh               Certificate inventory
  doctor.sh               Health checks
hooks/reload-cert.sh      Deploy hook called by acme.sh and certbot
install.sh                Orchestrated installer
```

## Contributing

Bug reports and pull requests are welcome. This project is small by design. Please keep patches focused and avoid introducing runtime dependencies.

## License

MIT. See [LICENSE](LICENSE).
