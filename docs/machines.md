# Example deployment scenarios

This document walks through four realistic archetypes of nginx-hosting
boxes and how `certease` behaves on each. It is **not** a real fleet
inventory — it is a reference so you can match your own server against
the closest archetype before running `certease install`.

## Summary

| Alias          | Role (archetype)                                           | Flavor | Tools             | CA(s)          | certease  |
|----------------|------------------------------------------------------------|--------|-------------------|----------------|-----------|
| `server-a`     | Multi-tenant web host, stock nginx                         | std    | acme.sh + certbot | LE (E7/E8)     | installed |
| `bt-server-1`  | Control-panel-managed host (`bt` layout)                   | bt     | acme.sh           | LE (migrated)  | installed |
| `lnmp-box`     | LNMP one-click stack, single-server scratch box            | lnmp   | acme.sh           | LE             | installed |
| `origin-edge`  | Cloud-VPS certbot-only node, 3 domains on a systemd timer  | std    | certbot           | LE             | not installed |

## Per-host notes

### `server-a` — `std` flavor, the main workhorse

- Nginx: stock `/etc/nginx` layout, systemd-managed.
- Hosts the majority of production vhosts for this archetype.
- **acme.sh**: ~10 domains, all Let's Encrypt (E7 / E8 intermediates).
- **certbot**: a few additional domains, healthy, `certbot.timer` active.
- `ACCOUNT_EMAIL=you@example.com` in `/etc/certease.conf`.
- `FALLBACK_CA=letsencrypt` (the default).
- A common finding on this archetype: `acme.sh --install-cronjob`
  had never been run — every acme.sh domain was silently un-renewed.
  Fixed automatically by `certease install`.

### `bt-server-1` — `bt` flavor, control-panel-managed

- Control-panel host. Certs live under
  `/www/server/panel/vhost/cert/<NAME>/fullchain.pem` + `privkey.pem`.
- Important quirk: the panel names the per-domain subdir after the
  **first `server_name` token** of the vhost — not after the acme.sh
  `Le_Domain`. A domain registered as `example.com` in acme.sh ends up
  under `/www/server/panel/vhost/cert/www.example.com/` because the
  vhost file `www.example.com.conf` starts with
  `server_name www.example.com example.com;`.
  `lib/nginx_flavors.sh :: bt_resolve_cert_dir()` resolves this.
- Migrated off ZeroSSL to Let's Encrypt because of `retryafter=`
  rate-limit stalls on renewal.
- HTTP-01 webroot is `/www/wwwroot/<acme-challenge-root>` — the
  panel's Lua handler for `.well-known/acme-challenge/` serves from a
  dedicated directory, not the per-vhost webroot.
- Account config `~/.acme.sh/account.conf` typically ships with
  `LOG_FILE=` commented out on this archetype; `certease install`
  enables it.

### `lnmp-box` — `lnmp` flavor, scratch box

- LNMP-style: nginx at `/usr/local/nginx`, vhosts in
  `/usr/local/nginx/conf/vhost`, certs under
  `/usr/local/nginx/conf/ssl/`.
- Typically ~8 domain directories in `~/.acme.sh`.
- Expect a few stale expired ZeroSSL certs from abandoned test
  domains. `certease doctor` flags them as orphans; safe to ignore
  or `rm -rf` when convenient — they do not block operation.
- acme.sh + cron + deploy hook wired via `certease install`.

### `origin-edge` — certbot only

- Pure certbot + systemd-timer; no acme.sh installed.
- A handful of domains, all healthy. `certbot.timer` active, LE
  account has an email.
- No `certease` install required — there is nothing to fix. Listed
  here only so it doesn't look like it was forgotten.

## Nginx-flavor detection truth table

| Directory test                             | Flavor  |
|--------------------------------------------|---------|
| `/www/server/panel/vhost/nginx` exists     | bt      |
| `/usr/local/nginx/conf/vhost` exists       | lnmp    |
| `/etc/nginx` exists                        | std     |
| none of the above                          | unknown |

First-match order. Control-panel hosts sometimes also carry
`/etc/nginx/`, so the `bt` check must come first.

## Deploy-hook wire-up (post-install state)

All `certease`-managed hosts have, on every acme.sh domain:

- `Le_ReloadCmd` pointing at `<install_dir>/hooks/reload-cert.sh`
- `--fullchain-file` / `--key-file` pointing into the canonical flavor
  SSL dir (for `bt`: resolved via `bt_resolve_cert_dir`)
- cron entry `0 0 * * * "<acme_home>/acme.sh" --cron ... >>
  /var/log/certease/certease-cron.log 2>&1`
- `LOG_FILE=/var/log/acme.sh.log` set in `account.conf`
