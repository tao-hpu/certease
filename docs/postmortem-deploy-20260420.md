# Certease v0.1.0 — Initial Deploy Postmortem

**Date**: 2026-04-20
**Hosts**: three heterogeneous production boxes — `server-a` (std), `bt-server-1` (bt), `lnmp-box` (lnmp)
**Outcome**: 17 certificates renewed, from critical (2 expiring in 24h, 4 in <15d) to all 75-90d fresh.

---

## 5 Real Bugs Found During Production Deploy

Every one of these bugs was invisible to `bash -n` / local testing. Only exposed by running against real acme.sh directories + real nginx installs.

### Bug 1: `status` reads CA cert instead of leaf cert
**Symptom**: Every cert showed `notAfter=2027-03-12, 326 days, OK` — even expired ones.
**Root cause**: `find "$dir" -maxdepth 1 -name '*.cer' | head -n1` picked `ca.cer` (intermediate) by alphabetical sort. OpenSSL parsed that cert's expiry instead of the leaf.
**Fix**: Prefer `$domain.cer` explicitly; fall back to `fullchain.cer`; blacklist `ca.cer`.
**File**: `lib/status.sh`, `bin/certease` (doctor subcommand had the same bug).

### Bug 2: `HOME=` override breaks acme.sh `--install-cert`
**Symptom**: `acme.sh: 'domain' is not an issued domain, skipping.` for every domain.
**Root cause**: Setting `HOME="$acme_home"` caused acme.sh to look at `$HOME/.acme.sh` = `/root/.acme.sh/.acme.sh/` (double path). The right way is `--home "$acme_home"` flag.
**Fix**: Replace all `HOME=...` prefixes with `--home` flag.
**File**: `lib/install_hook.sh`, `lib/install_cron.sh`.

### Bug 3: `acme_conf_get` reads `.csr.conf` instead of `.conf`
**Symptom**: `doctor` reported `Le_ReloadCmd is empty` for 4 of 8 domains even though they were set.
**Root cause**: `find "$dir" -name '*.conf' | head -n1` sometimes returned `<domain>.csr.conf` (temporary CSR config) instead of `<domain>.conf` (the real acme.sh state). Filesystem order (not alphabetical) decided.
**Fix**: Prefer `$domain.conf` explicitly; blacklist `*.csr.conf` in fallback.
**File**: `lib/detect.sh`.

### Bug 4: `nginx reload_cmd` hardcodes bare `nginx` binary
**Symptom**: Hook fails with `nginx: command not found` on LNMP/BT hosts.
**Root cause**: `nginx_reload_cmd` returned `nginx -s reload`, but on LNMP the binary is at `/usr/local/nginx/sbin/nginx` (not in PATH), and on BT at `/www/server/nginx/sbin/nginx`.
**Fix**: Fall back to `$(detect_nginx_bin) -s reload` instead of bare `nginx`.
**File**: `lib/nginx_flavors.sh`.

### Bug 5: Wrong env var names in reload hook
**Symptom**: Hook exits silently before logging; acme.sh reports `Reload error`.
**Root cause**: Required `FULLCHAIN_PATH` / `KEY_PATH` env vars — but acme.sh actually exports `CERT_FULLCHAIN_PATH` / `CERT_KEY_PATH`. Hook tripped `: "${FULLCHAIN_PATH:?...}"` check and exited before any log line.
**Fix**: Accept both names; fall back to `$DOMAIN_PATH/fullchain.cer` if neither is set.
**File**: `hooks/reload-cert.sh`.

---

## 3 Real Infrastructure Issues Surfaced (Not Tool Bugs)

### Issue A: `bt-server-1`'s 2 months of silent failures
**Finding**: Three layered errors hid the problem:
1. `Le_Webroot='/www/wwwroot/www.example.com'` pointed to an empty dir
2. Control panel's `location ~ \.well-known` regex caught the path but served from `$document_root` = the empty dir
3. `LOG_FILE` was commented out in `account.conf` + cron stdout `>/dev/null` → no visible failures
**Fix**: Discovered the panel's lua block in the `well-known` include serves from a dedicated path (`/www/wwwroot/<acme-challenge-root>/`) as a last-resort. Point webroot there. Also: certease `install` now enables `LOG_FILE`.

### Issue B: `return 301` at nginx server level runs BEFORE location matching
**Finding**: On one of the vhosts, even with `location ^~ /.well-known/acme-challenge/ {...}` present, LE got 404 because `return 301` at server level fired first (rewrite phase).
**Fix**: Wrap `return 301` in `location / { ... }` to subordinate it to location matching.

### Issue C: `bt` panel uses vhost's first `server_name` as cert dir, not Le_Domain
**Finding**: `example.com` cert issued to `/www/server/panel/vhost/cert/example.com/` but nginx reads from `/www/server/panel/vhost/cert/www.example.com/` (dir name = first token in `server_name www.example.com example.com;`).
**Fix**: Added `bt_resolve_cert_dir()` in `lib/nginx_flavors.sh` that scans vhost files for `ssl_certificate` paths and maps Le_Domain → actual BT subdirectory.

---

## Fallback CA Proven Working

One domain (on `bt-server-1`) was rate-limited by ZeroSSL (`retryafter=86400` after prior failed attempts). `FALLBACK_CA="letsencrypt"` auto-retried and succeeded — the fallback-eligibility detector (`_renew_fallback_eligible`) correctly triggered on the retry-after error.

## `.bak` files in `sites-enabled/` cause "conflicting server name" warnings

nginx loads every file in `sites-enabled/*` regardless of extension — `.bak` suffixed backups are picked up too, creating duplicate server_name declarations. Store backups outside `sites-enabled/` (we use `/root/nginx-vhost-backups/`).

---

## Numbers

- 17 certificates renewed (across 3 hosts)
- 5 tool bugs fixed
- 3 infrastructure issues surfaced (fixed ad-hoc; longer-term solutions queued)
- 2 nearly-expired certs saved within hours of cutoff (~24h and ~23h remaining respectively)
- 2 months of silent rotation failures ended on the `bt` host
- 0 downtime during deploy
