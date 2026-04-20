# Changelog

All notable changes to `certease` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] — 2026-04-20

First tagged release. Deployed on three heterogeneous production hosts
(representing `std`, `bt`, and `lnmp` nginx flavors) and validated
end-to-end. A fourth host (certbot-only, `std` flavor) was confirmed
healthy without needing `certease`.

### Added

- `certease install | status | doctor | renew` subcommands.
- `hooks/reload-cert.sh` flavor-aware deploy hook.
- `/etc/certease.conf` declarative host override (via
  `config/certease.conf.example`).
- `FALLBACK_CA` support in `renew` — auto-retries rate-limited or
  transient CA errors against a different CA (default
  `"letsencrypt"`; set to `""` to disable).
- `bt_resolve_cert_dir()` in `lib/nginx_flavors.sh`: resolves the
  correct BT per-domain cert subdirectory by walking `/www/server/panel/vhost/nginx/*.conf`
  and matching `server_name`.
- Docs: `docs/machines.md` fleet inventory; this `CHANGELOG.md`.

### Fixed

Five bugs surfaced during the initial deployment to the three production
hosts. All are resolved in this release.

- **#1 — Wrong acme.sh conf file picked for `Le_*` reads.**
  `acme_conf_get()` in `lib/detect.sh` was returning fields from the
  `<domain>.csr.conf` file, which does not contain `Le_ReloadCmd` or
  `Le_NextRenewTime`. `doctor` therefore reported every domain as
  "reload cmd empty" even when it was correctly set. Fixed by
  preferring `<domain>.conf` explicitly and excluding `*.csr.conf`.

- **#2 — `nginx -s reload` not in PATH on LNMP / BT hosts.**
  `hooks/reload-cert.sh` ran `nginx -s reload`, but on LNMP
  (`/usr/local/nginx/sbin/nginx`) and BT (`/www/server/nginx/sbin/nginx`)
  the bare binary isn't in root's PATH under cron. Deploy silently
  failed to reload. Fixed by introducing `nginx_reload_cmd()` which
  prefers `systemctl reload nginx` when the unit exists and falls back
  to the fully-qualified binary path via `detect_nginx_bin`.

- **#3 — `acme.sh --install-cronjob` output swallowed.**
  The vendor's installer writes `> /dev/null` into the crontab line,
  which is the root cause of the "silent renewal failure" pattern we
  observed on a BT-panel host. `ensure_acme_cron()` now rewrites any matching cron line to
  append `>>$LOG_DIR/certease-cron.log 2>&1`.

- **#4 — `FALLBACK_CA` retry shelled out before log was flushed.**
  Initial version of `_renew_fallback_eligible()` checked the log file
  while acme.sh was still writing to it, so the regex sometimes missed
  `retryafter=` lines. Fixed by running the primary `acme.sh --renew`
  with stdout/stderr to the log via a single `>` (not append), waiting
  for exit, then grepping. Retry now also appends `--- primary attempt
  failed ---` separator to the same log for post-mortem clarity.

- **#5 — BT per-domain cert subdirectory mis-resolved.**
  On BT (宝塔) hosts, nginx vhosts reference
  `/www/server/panel/vhost/cert/<NAME>/fullchain.pem` where `<NAME>` is
  the **first `server_name` token** in the vhost, not necessarily the
  acme.sh `Le_Domain`. Example: acme.sh domain `example.com` → vhost
  `server_name www.example.com example.com;` → BT subdir `www.example.com/`. The hook
  was writing the new cert to `/www/server/panel/vhost/cert/example.com/`
  and nginx kept serving the old cert. Fixed by adding
  `bt_resolve_cert_dir()` (see Added) and routing both
  `install_hook.sh` and `hooks/reload-cert.sh` through it. Falls back
  to the canonical domain name when no vhost match is found, so fresh
  BT hosts work correctly before the first deploy.

### Known limitations

- Only HTTP-01 is wired end-to-end; DNS-01 is supported via acme.sh's
  own providers but not managed by `certease`.
- Wildcard certs (`*.example.com`) must be issued manually — HTTP-01
  cannot validate them.
- Only bash 4+ hosts tested; no effort made to support older shells.
