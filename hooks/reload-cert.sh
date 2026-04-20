#!/usr/bin/env bash
# hooks/reload-cert.sh — acme.sh deploy hook.
#
# acme.sh invokes this with the following env vars when running reloadcmd:
#   Le_Domain              — bare domain name
#   CERT_PATH              — leaf cert (<domain>.cer)
#   CERT_KEY_PATH          — private key
#   CERT_FULLCHAIN_PATH    — leaf + intermediate chain
#   CA_CERT_PATH           — intermediate only
#   DOMAIN_PATH            — acme.sh's working directory for this domain
# (Some older docs list FULLCHAIN_PATH / KEY_PATH — those are wrong.)
#
# Responsibilities:
#   1. Copy fullchain + key into the canonical nginx SSL dir for this flavor.
#   2. `nginx -t` — bail out without reloading if the test fails.
#   3. Reload nginx.
#   4. Optionally POST a failure to $ALERT_WEBHOOK.

set -euo pipefail

# --- locate our toolkit -------------------------------------------------------
HOOK_SELF="${BASH_SOURCE[0]}"
HOOK_DIR="$(cd "$(dirname "$HOOK_SELF")" && pwd)"
ROOT_DIR="$(cd "$HOOK_DIR/.." && pwd)"

# shellcheck source=../lib/common.sh
. "$ROOT_DIR/lib/common.sh"
# shellcheck source=../lib/detect.sh
. "$ROOT_DIR/lib/detect.sh"
# shellcheck source=../lib/nginx_flavors.sh
. "$ROOT_DIR/lib/nginx_flavors.sh"

load_config
LOG_DIR_RESOLVED="$(ensure_log_dir)"
HOOK_LOG="$LOG_DIR_RESOLVED/hook.log"

_hlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$HOOK_LOG" >&2
}

_fail() {
  _hlog "FAIL: $*"
  if [[ -n "${ALERT_WEBHOOK:-}" ]] && command -v curl >/dev/null 2>&1; then
    curl -fsS -m 5 -X POST -H 'Content-Type: application/json' \
      -d "{\"host\":\"$(hostname)\",\"domain\":\"${Le_Domain:-?}\",\"error\":\"$*\"}" \
      "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
  fi
  exit 1
}

# --- inputs -------------------------------------------------------------------
: "${Le_Domain:?Le_Domain not set by acme.sh}"
# Accept both modern (CERT_FULLCHAIN_PATH / CERT_KEY_PATH) and legacy
# (FULLCHAIN_PATH / KEY_PATH) names; let the hook be tolerant.
FULLCHAIN_SRC="${CERT_FULLCHAIN_PATH:-${FULLCHAIN_PATH:-}}"
KEY_SRC="${CERT_KEY_PATH:-${KEY_PATH:-}}"
if [[ -z "$FULLCHAIN_SRC" ]]; then
  # Fall back to DOMAIN_PATH/fullchain.cer if acme.sh didn't export either var.
  if [[ -n "${DOMAIN_PATH:-}" && -f "$DOMAIN_PATH/fullchain.cer" ]]; then
    FULLCHAIN_SRC="$DOMAIN_PATH/fullchain.cer"
    KEY_SRC="${KEY_SRC:-$DOMAIN_PATH/$Le_Domain.key}"
  else
    _hlog "FAIL: CERT_FULLCHAIN_PATH not set and cannot derive from DOMAIN_PATH"
    exit 1
  fi
fi
[[ -n "$KEY_SRC" ]] || { _hlog "FAIL: CERT_KEY_PATH not set"; exit 1; }

FLAVOR="$(detect_nginx_flavor)"
if [[ "$FLAVOR" == "unknown" ]]; then
  _fail "Cannot detect nginx flavor on this host"
fi

# SSL_DEPLOY_DIR from config overrides flavor detection.
if [[ -n "${SSL_DEPLOY_DIR:-}" ]]; then
  TARGET_DIR="$SSL_DEPLOY_DIR"
  case "$FLAVOR" in
    bt)
      # Even with an override, BT's per-domain subdir must match the vhost's
      # first server_name — otherwise nginx keeps serving the stale cert.
      BT_SUBDIR="$(bt_resolve_cert_dir "$Le_Domain")"
      [[ -z "$BT_SUBDIR" ]] && BT_SUBDIR="$Le_Domain"
      TARGET_CRT="$TARGET_DIR/$BT_SUBDIR/fullchain.pem"
      TARGET_KEY="$TARGET_DIR/$BT_SUBDIR/privkey.pem"
      ;;
    *)
      TARGET_CRT="$TARGET_DIR/$Le_Domain.crt"
      TARGET_KEY="$TARGET_DIR/$Le_Domain.key"
      ;;
  esac
else
  paths="$(nginx_cert_paths "$FLAVOR" "$Le_Domain")" || _fail "nginx_cert_paths returned nothing"
  TARGET_CRT="$(printf '%s\n' "$paths" | sed -n '1p')"
  TARGET_KEY="$(printf '%s\n' "$paths" | sed -n '2p')"
fi

_hlog "deploy start: domain=$Le_Domain flavor=$FLAVOR crt=$TARGET_CRT"

# --- copy ---------------------------------------------------------------------
mkdir -p "$(dirname "$TARGET_CRT")" || _fail "mkdir $(dirname "$TARGET_CRT")"

install -m 0644 "$FULLCHAIN_SRC" "$TARGET_CRT" || _fail "copy fullchain → $TARGET_CRT"
install -m 0600 "$KEY_SRC"       "$TARGET_KEY" || _fail "copy key → $TARGET_KEY"

# --- test & reload ------------------------------------------------------------
NGINX_BIN="$(detect_nginx_bin || true)"
if [[ -z "$NGINX_BIN" ]]; then
  _fail "nginx binary not found"
fi

if ! "$NGINX_BIN" -t >>"$HOOK_LOG" 2>&1; then
  _fail "nginx -t failed — NOT reloading (see $HOOK_LOG)"
fi

RELOAD_CMD="$(nginx_reload_cmd)"
# shellcheck disable=SC2086
if ! eval "$RELOAD_CMD" >>"$HOOK_LOG" 2>&1; then
  _fail "nginx reload failed: $RELOAD_CMD"
fi

_hlog "deploy ok: $Le_Domain reloaded via '$RELOAD_CMD'"
exit 0
