# certease

> Also available in [中文](README.md)
>
> A small bash toolkit that keeps `acme.sh`, `certbot`, and `nginx` aligned
> on heterogeneous Linux fleets. Wraps the proven ACME clients — does not
> replace them — and fixes the ops ergonomics that actually kill certs in
> production.

```
sudo ./install.sh
certease install      # wire cron + logging + deploy hook on every domain
certease status       # aligned cert table; cron-friendly 0/1/2 exit codes
certease doctor       # ~15 invariant checks with [OK]/[WARN]/[FAIL] lines
certease renew        # renew due domains; auto-fallback CA on rate limits
```

No runtime dependencies beyond what a standard nginx host already has
(`bash 4+`, `openssl`, `awk`, `sed`, `crontab`, `find`, `date`).

---

## Why this exists

Born from debugging four heterogeneous servers in a single day — a plain
`nginx` host, an LNMP one-click install, two hosts behind a non-standard
control panel, and a pure-certbot cloud node. Every machine carried its
own sharp edge: non-standard binary paths outside cron's `$PATH`,
vhost-driven cert-directory naming that drifted from acme.sh's domain
key, a top-level `return 301` intercepting the `acme-challenge` path,
plus the evergreen "cron line silently redirected to `/dev/null`" that
hid two months of failed renewals.

Each one is trivial to fix when an AI walks you through it. The
expensive part is having to re-derive the same fix the next time you
touch a new server. So this toolkit is the one-time precipitation of
that day's findings: `git clone && bash install.sh` and every lesson
learned is already applied.

---

## What it is / isn't

**It is**: an ops-layer wrapper that makes `acme.sh` (and coexisting
`certbot`) safe to run unattended on mixed fleets.

**It isn't**:
- An ACME client replacement — it shells out to `acme.sh` and `certbot`.
- A DNS-01 orchestrator — use `acme.sh`'s dnsapi providers directly;
  certease will pick up those renewals on its next run.
- An installer for `acme.sh` or `certbot` themselves — if they aren't
  on the box, certease refuses to run.
- Opinionated about the contents of your certs (SANs, CA choice,
  key type). Those belong to the upstream client.

---

## When to use this

**Fits well**:
- Mixed fleets (stock nginx + LNMP + non-standard panels) under one team.
- Managed-services / MSP work: inheriting a server you didn't build.
- Small-to-mid companies with on-prem + a bit of cloud.
- Anywhere SSL renewal is a yearly time-bomb nobody wants to audit.

**Doesn't fit**:
- Pure Docker / K8s (use cert-manager).
- Fully-cloud certificates (use ACM / Cloudflare).
- A single-domain personal blog (plain certbot is enough).

---

## Differentiators

| Capability | Typical tooling | certease |
|---|---|---|
| Auto-detect nginx flavor | Manual configuration | `std` / `lnmp` / `bt` detected; paths mapped |
| Non-standard control-panel layouts | Rarely supported | Parses vhost `server_name` to derive cert subdirectory |
| Fallback CA on rate-limit | Roll your own | ZeroSSL retry-after → auto-retry with Let's Encrypt |
| Observability | One log line | `doctor` command + `hook.log` + per-renew logs |
| Runtime dependencies | Python / Node / Go | Pure bash, zero runtime deps |

---

## Quickstart

```sh
git clone <repo> /opt/certease
cd /opt/certease && sudo ./install.sh

sudo certease install --dry-run   # show the plan, write nothing
sudo certease install             # do it
certease status
certease doctor
```

After the first `install` you also get `/etc/certease.conf`. Every key
there is optional — the defaults are correct for most hosts.

---

## Subcommands

### `certease install [--dry-run]`

Idempotent bring-up. On each run:

1. Detects `acme.sh` home, `certbot`, and nginx flavor.
2. Ensures an `acme.sh --cron` entry exists and its output is redirected
   to `$LOG_DIR/certease-cron.log` (not `/dev/null`).
3. Uncomments / sets `LOG_FILE` and `LOG_LEVEL=1` in `account.conf`.
4. For every acme.sh domain, runs `acme.sh --install-cert` with
   `--reloadcmd` pointing at `hooks/reload-cert.sh` and
   `--fullchain-file` / `--key-file` pointing into the canonical SSL
   directory for this nginx flavor.
5. Installs `/etc/certease.conf` from the example (never overwrites).
6. If `ACCOUNT_EMAIL` is set, syncs it to both acme.sh and certbot.

### `certease status`

Aligned table, acme.sh + certbot combined:

```
TOOL     DOMAIN                           CA                 NOT_AFTER     DAYS  STATUS
acme.sh  example.com                      LE E7              2026-05-12    22    WARN
acme.sh  api.example.com                  LE E7              2026-06-19    60    OK
certbot  www.example.org                  LE E8              2026-06-06    47    OK
```

Exit `0` / `1` / `2` for `all-OK` / `WARN` / `CRITICAL`.

### `certease doctor`

Runs invariant checks, one `[OK]` / `[WARN]` / `[FAIL]` line each.
Covers cron entry, `LOG_FILE`, per-domain `Le_ReloadCmd`,
`Le_NextRenewTime` in past, `.cer` mtime, `ssl_certificate` paths on
disk, `nginx -t`, orphan acme.sh dirs, `certbot.timer`, certbot
account email.

### `certease renew [--force] [-d DOMAIN]`

Iterates acme.sh domains. Renews those whose `Le_NextRenewTime` is
past. `--force` to renew all. Per-run log at
`$LOG_DIR/renew-<domain>-<timestamp>.log`. Does not touch certbot —
it has its own systemd timer.

---

## Fallback CA

On a fallback-eligible failure (ZeroSSL rate-limit, transient 5xx,
Buypass `serverInternal`), certease retries once against a different
CA specified by `FALLBACK_CA`:

```sh
# /etc/certease.conf
FALLBACK_CA="letsencrypt"     # default
# FALLBACK_CA=""              # disable
```

Fallback does **not** paper over misconfiguration — DNS-01 with wrong
zone, HTTP-01 webroot returning 404, or a domain not pointed at this
host all fail the same way on every CA. certease detects those and
fails fast.

---

## Nginx flavor matrix

| Flavor | Detected when | Cert deploy dir | Per-domain path | Notable quirk |
|---|---|---|---|---|
| `std` | `/etc/nginx` exists | `/etc/nginx/ssl` | `<dir>/<domain>.crt` + `.key` | none |
| `lnmp` | `/usr/local/nginx/conf/vhost` exists | `/usr/local/nginx/conf/ssl` | `<dir>/<domain>.crt` + `.key` | `nginx` binary not in PATH under cron |
| `bt` | `/www/server/panel/vhost/nginx` exists | `/www/server/panel/vhost/cert` | `<dir>/<NAME>/fullchain.pem` + `privkey.pem` | `<NAME>` = first `server_name` token in vhost, not the acme.sh domain |

Detection is first-match in the above order. Override with
`SSL_DEPLOY_DIR` in `/etc/certease.conf`.

### The `bt` subdirectory quirk

On control-panel hosts (the `bt` flavor here), the per-domain
subdirectory under `/www/server/panel/vhost/cert/` is named after the
**first `server_name` token** in the vhost file, which is not
necessarily the acme.sh `Le_Domain`. Example:

```
acme.sh domain:  example.com
vhost file:      /www/server/panel/vhost/nginx/www.example.com.conf
vhost directive: server_name www.example.com example.com;
cert dir:        /www/server/panel/vhost/cert/www.example.com/
                                             ^^^^^^^^^^^^^^^
```

Writing certs to `.../cert/example.com/` silently does nothing.
`certease`'s `bt_resolve_cert_dir()` walks the vhost files and resolves
the correct subdirectory automatically.

---

## Troubleshooting

### "Renewal succeeds but nginx still serves the old cert"

Almost always one of:

- **`Le_ReloadCmd` is empty.** `certease doctor` flags it; `certease install` fixes it.
- **On `bt` hosts: cert written to `.../cert/<Le_Domain>/`, nginx reading `.../cert/<first_server_name>/`.** See the quirk above; `bt_resolve_cert_dir()` handles it.
- **Reload never happened.** Check `$LOG_DIR/hook.log` for `nginx reload failed:`.

```sh
nginx -T 2>/dev/null | grep -E 'ssl_certificate\s' | sort -u
stat ~/.acme.sh/<domain>_ecc/fullchain.cer
```

### "404 on /.well-known/acme-challenge/"

- A regex `location ~ \.well-known` takes priority over the default
  handler. Use `location ^~ /.well-known/acme-challenge/`.
- HTTP-to-HTTPS redirect fires before the challenge path can match.
  Exempt `/.well-known/acme-challenge/` from the redirect.
- **`return 301` at server level runs in the rewrite phase, before
  location matching.** Wrap it in `location / { return 301 ... }` to
  subordinate it. This one is easy to miss.

### "Domain is not in issued list"

Usually a `--home` mismatch. certease always passes explicit `--home`.
Outside certease, confirm `~/.acme.sh/<domain>/<domain>.conf` exists
before renewing.

### "Rate-limited by ZeroSSL, retry-after 24h"

Set `FALLBACK_CA="letsencrypt"` in `/etc/certease.conf` and re-run
`certease renew`. The retry uses LE for this one renewal; the primary
CA choice is unaffected.

### "Wildcard cert renewal fails"

HTTP-01 cannot validate wildcards. Either switch to DNS-01 (acme.sh
dnsapi; certease picks it up on next run) or split into per-name certs.

### "`--issue --force` did not reload nginx"

`acme.sh --issue --force` does **not** invoke the `--reloadcmd` you
configured at `--install-cert` time, nor copy into the deploy dir.
Run `certease renew -d <domain>` instead — certease's renewal path
always goes through the hook.

---

## Configuration

`/etc/certease.conf` is sourced as bash. All keys optional; see
`config/certease.conf.example` for the fully-commented template.

```sh
SSL_DEPLOY_DIR=""
NGINX_RELOAD_CMD=""
LOG_DIR="/var/log/certease"
WARN_DAYS=30
CRITICAL_DAYS=14
ALERT_WEBHOOK=""
ACCOUNT_EMAIL=""
FALLBACK_CA="letsencrypt"
```

---

## Design

**Why bash only.** Every nginx box already has bash, openssl, crontab.
Adding Python or Node multiplies the support matrix across distros and
versions. Bash behaves the same on all of them.

**Why wrap, not replace.** `acme.sh` is mature, battle-tested, and
supports dozens of DNS providers and CA quirks. Rewriting it is a
multi-year project for no user benefit. The real pain is operational —
bad defaults, easy-to-forget setup, missing visibility. certease fixes
exactly that layer.

**Why `/etc/certease.conf`.** Declarative per-host override that
survives toolkit upgrades. Ansible / Puppet / cloud-init can drop the
file in place; `certease install` picks it up on next run.

**Knowledge precipitation.** This project is an experiment in
converting AI-assisted debugging from disposable chat sessions into a
clonable, reusable tool. Letting an AI re-derive the same fix every
time you touch a new server is slow, error-prone, and wasteful. Codify
once, reuse forever.

---

## Development

- `bash -n` clean on every file.
- Targets `bash 4+`; no bash-5-only features.
- `set -euo pipefail` everywhere.
- No `sudo` inside scripts — run as root.
- User-facing strings in English.

```sh
bash -c '. lib/common.sh; . lib/detect.sh; detect_acme_home; detect_nginx_flavor'
./bin/certease --help
./bin/certease install --dry-run
```

---

## Contributing

PRs welcome. Keep it bash; no Python / Node / Go. Every `doctor` check
must be stateless and idempotent. Update `CHANGELOG.md` for anything
user-visible. `bash -n` must pass; `shellcheck` should be clean.

Bug reports with `certease doctor` output attached get answered fastest.

---

## License

MIT — see `LICENSE`.
