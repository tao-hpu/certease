# shellcheck shell=bash
# lib/detect.sh — environment detection: acme.sh home, certbot, nginx flavor.

if [[ -n "${__CERTEASE_DETECT_LOADED:-}" ]]; then
  return 0
fi
__CERTEASE_DETECT_LOADED=1

# Echoes the acme.sh home dir (contains account.conf + *_ecc/ subdirs) or empty.
detect_acme_home() {
  local candidates=(
    "${HOME:-}/.acme.sh"
    "/root/.acme.sh"
    "/home/acme/.acme.sh"
  )
  for c in "${candidates[@]}"; do
    if [[ -n "$c" && -d "$c" && -f "$c/account.conf" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  return 1
}

# Echoes the full path to the acme.sh script inside the detected home, or empty.
detect_acme_bin() {
  local home
  home="$(detect_acme_home || true)"
  if [[ -n "$home" && -x "$home/acme.sh" ]]; then
    printf '%s\n' "$home/acme.sh"
    return 0
  fi
  if command -v acme.sh >/dev/null 2>&1; then
    command -v acme.sh
    return 0
  fi
  return 1
}

# Echoes path to certbot binary, or empty.
detect_certbot_bin() {
  command -v certbot 2>/dev/null || return 1
}

# Is certbot.timer active (systemd)?
detect_certbot_timer_active() {
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet certbot.timer 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# Echoes one of: bt | lnmp | std | unknown.
detect_nginx_flavor() {
  if [[ -d /www/server/panel/vhost/nginx ]]; then
    printf 'bt\n'
  elif [[ -d /usr/local/nginx/conf/vhost ]]; then
    printf 'lnmp\n'
  elif [[ -d /etc/nginx ]]; then
    printf 'std\n'
  else
    printf 'unknown\n'
  fi
}

# Echoes path to nginx binary (for `-t` tests), or empty.
detect_nginx_bin() {
  for c in /usr/sbin/nginx /usr/local/nginx/sbin/nginx /www/server/nginx/sbin/nginx; do
    if [[ -x "$c" ]]; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  command -v nginx 2>/dev/null || return 1
}

# Enumerate acme.sh domain directories (both *_ecc/ and legacy RSA).
# Prints one path per line. Skips dirs with no .cer file.
list_acme_domains() {
  local home="$1"
  [[ -d "$home" ]] || return 0
  find "$home" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r d; do
    local base
    base="$(basename "$d")"
    case "$base" in
      "ca"|"deploy"|"dnsapi"|"http.header"|"notify") continue ;;
    esac
    if compgen -G "$d/*.cer" >/dev/null; then
      printf '%s\n' "$d"
    fi
  done
}

# Given a domain dir, print the domain name (strip _ecc suffix).
acme_dir_to_domain() {
  local d="$1"
  local b
  b="$(basename "$d")"
  printf '%s\n' "${b%_ecc}"
}

# Read a KEY=val line from an acme.sh domain's *.conf.
# Prints the value without surrounding quotes; empty if unset.
acme_conf_get() {
  local dir="$1" key="$2"
  local conf domain
  # Prefer <domain>.conf explicitly. Each acme.sh dir also contains <domain>.csr.conf
  # which holds only CSR-related fields — picking it by accident hides Le_ReloadCmd.
  domain="$(acme_dir_to_domain "$dir")"
  if [[ -f "$dir/$domain.conf" ]]; then
    conf="$dir/$domain.conf"
  else
    conf="$(find "$dir" -maxdepth 1 -name '*.conf' ! -name '*.csr.conf' | head -n1)"
  fi
  [[ -z "$conf" || ! -f "$conf" ]] && return 0
  local line
  line="$(grep -E "^${key}=" "$conf" | tail -n1 || true)"
  [[ -z "$line" ]] && return 0
  local val="${line#"${key}"=}"
  val="${val%\'}"
  val="${val#\'}"
  val="${val%\"}"
  val="${val#\"}"
  printf '%s\n' "$val"
}
