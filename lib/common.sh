# shellcheck shell=bash
# lib/common.sh — logging, colors, small helpers.
# Sourced by bin/certease and other lib/*.sh files.
# Do not execute directly.

# Guard against double-sourcing.
if [[ -n "${__CERTEASE_COMMON_LOADED:-}" ]]; then
  return 0
fi
__CERTEASE_COMMON_LOADED=1

# Colors only when stdout is a TTY and NO_COLOR is unset.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_GREEN=$'\033[32m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED=""
  C_YELLOW=""
  C_GREEN=""
  C_BLUE=""
  C_DIM=""
  C_BOLD=""
  C_RESET=""
fi

log()   { printf '%s[certease]%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
warn()  { printf '%s[certease WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()   { printf '%s[certease ERR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
ok()    { printf '%s[certease OK]%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
debug() {
  if [[ -n "${CERTEASE_DEBUG:-}" ]]; then
    printf '%s[certease DEBUG]%s %s\n' "$C_DIM" "$C_RESET" "$*" >&2
  fi
}

die() {
  err "$*"
  exit 2
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This action must be run as root (not via sudo inside scripts). Re-run as root."
  fi
}

# Locate the toolkit install dir from any sourcing script.
certease_root() {
  # Callers set CERTEASE_ROOT before sourcing; fall back to this file's grandparent.
  if [[ -n "${CERTEASE_ROOT:-}" ]]; then
    printf '%s\n' "$CERTEASE_ROOT"
    return 0
  fi
  local self
  self="${BASH_SOURCE[0]}"
  (cd "$(dirname "$self")/.." && pwd)
}

# Load /etc/certease.conf into the current shell if it exists.
load_config() {
  SSL_DEPLOY_DIR="${SSL_DEPLOY_DIR:-}"
  NGINX_RELOAD_CMD="${NGINX_RELOAD_CMD:-}"
  LOG_DIR="${LOG_DIR:-/var/log/certease}"
  WARN_DAYS="${WARN_DAYS:-30}"
  CRITICAL_DAYS="${CRITICAL_DAYS:-14}"
  ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
  ACCOUNT_EMAIL="${ACCOUNT_EMAIL:-}"
  FALLBACK_CA="${FALLBACK_CA:-letsencrypt}"
  if [[ -f /etc/certease.conf ]]; then
    # shellcheck disable=SC1091
    . /etc/certease.conf
  fi
}

ensure_log_dir() {
  load_config
  if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || {
      warn "Cannot create $LOG_DIR; falling back to /tmp"
      LOG_DIR="/tmp"
    }
  fi
  printf '%s\n' "$LOG_DIR"
}

# Portable epoch-from-date for OpenSSL "notAfter" strings.
# Works on GNU date and BSD date (macOS). Returns empty on failure.
date_to_epoch() {
  local s="$1"
  local epoch=""
  # Try GNU date first.
  epoch="$(date -d "$s" +%s 2>/dev/null || true)"
  if [[ -n "$epoch" ]]; then
    printf '%s\n' "$epoch"
    return 0
  fi
  # BSD fallback — try a few common formats.
  for fmt in "%b %e %H:%M:%S %Y %Z" "%b %d %H:%M:%S %Y %Z" "%Y-%m-%d %H:%M:%S" "%Y-%m-%dT%H:%M:%SZ"; do
    epoch="$(date -j -f "$fmt" "$s" +%s 2>/dev/null || true)"
    if [[ -n "$epoch" ]]; then
      printf '%s\n' "$epoch"
      return 0
    fi
  done
  return 1
}

days_until() {
  local target_epoch="$1"
  local now
  now="$(date +%s)"
  printf '%s\n' $(( (target_epoch - now) / 86400 ))
}
