# shellcheck shell=bash
# lib/nginx_flavors.sh — canonical SSL paths and reload commands per nginx flavor.

if [[ -n "${__CERTEASE_FLAVORS_LOADED:-}" ]]; then
  return 0
fi
__CERTEASE_FLAVORS_LOADED=1

# Canonical SSL deploy directory for a flavor.
# Note: bt stores certs per-domain at /www/server/panel/vhost/cert/<domain>/
# so callers must append /<domain>/ when flavor=bt.
nginx_ssl_dir() {
  case "$1" in
    bt)   printf '/www/server/panel/vhost/cert\n' ;;
    lnmp) printf '/usr/local/nginx/conf/ssl\n' ;;
    std)  printf '/etc/nginx/ssl\n' ;;
    *)    return 1 ;;
  esac
}

# For BT (宝塔) hosts, the per-domain cert subdirectory under
# /www/server/panel/vhost/cert/ is named after the FIRST server_name in
# the nginx vhost, NOT necessarily after the canonical acme.sh Le_Domain.
#
# Example:
#   acme.sh stores    ~/.acme.sh/example.com_ecc/
#   vhost file        /www/server/panel/vhost/nginx/www.example.com.conf
#   vhost directive   server_name www.example.com example.com;
#   BT cert dir       /www/server/panel/vhost/cert/www.example.com/   <- "www.example.com"
#
# Writing to /www/server/panel/vhost/cert/example.com/ would silently do nothing
# because nginx's `ssl_certificate` points at the www.example.com subdir.
#
# This function walks vhost files under /www/server/panel/vhost/nginx/*.conf,
# finds any ssl_certificate directive pointing into the BT cert tree, reads
# the vhost's server_name list, and if the requested domain is one of those
# names returns the <NAME> subdir that BT actually uses.
#
# Falls back to echoing the input domain when no match is found — this keeps
# behavior sane on fresh BT hosts before any cert has been deployed.
#
# Usage:  bt_resolve_cert_dir example.com   -> prints e.g. "www.example.com"
bt_resolve_cert_dir() {
  local domain="$1"
  local vhost_glob="/www/server/panel/vhost/nginx"
  local cert_root="/www/server/panel/vhost/cert"

  if [[ -z "$domain" ]]; then
    return 1
  fi

  # On non-BT hosts this dir won't exist; return input unchanged.
  if [[ ! -d "$vhost_glob" ]]; then
    printf '%s\n' "$domain"
    return 0
  fi

  local conf cert_path subdir names
  shopt -s nullglob
  for conf in "$vhost_glob"/*.conf; do
    [[ -f "$conf" ]] || continue
    # Find each ssl_certificate line pointing into the BT cert root.
    # (A single vhost can reference only one cert, but iterate defensively.)
    while IFS= read -r cert_path; do
      [[ -z "$cert_path" ]] && continue
      # Extract <NAME> from ".../cert/<NAME>/fullchain.pem".
      subdir="${cert_path#"$cert_root"/}"
      subdir="${subdir%%/*}"
      [[ -z "$subdir" || "$subdir" == "$cert_path" ]] && continue

      # Collect all server_name tokens from this vhost (may span multiple lines).
      names="$(awk '
        /^[[:space:]]*server_name[[:space:]]/ {
          sub(/^[[:space:]]*server_name[[:space:]]+/, "");
          sub(/;.*$/, "");
          print
        }' "$conf" | tr -s '[:space:]' '\n' | sed '/^$/d')"

      # If the requested domain appears, use this vhost's BT subdir.
      if printf '%s\n' "$names" | grep -Fxq "$domain"; then
        shopt -u nullglob
        printf '%s\n' "$subdir"
        return 0
      fi
    done < <(awk '/^[[:space:]]*ssl_certificate[[:space:]]/ && !/_key/ {
                    gsub(";", "");
                    print $2
                  }' "$conf" 2>/dev/null | grep -F "$cert_root/" || true)
  done
  shopt -u nullglob

  # Fallback: no vhost references this domain yet — use the canonical name.
  printf '%s\n' "$domain"
}

# Given flavor + domain, print the full target paths for cert + key.
# Output: two lines — CRT_PATH then KEY_PATH.
nginx_cert_paths() {
  local flavor="$1" domain="$2"
  local base subdir
  base="$(nginx_ssl_dir "$flavor")" || return 1
  case "$flavor" in
    bt)
      subdir="$(bt_resolve_cert_dir "$domain")"
      [[ -z "$subdir" ]] && subdir="$domain"
      printf '%s/%s/fullchain.pem\n' "$base" "$subdir"
      printf '%s/%s/privkey.pem\n'   "$base" "$subdir"
      ;;
    *)
      printf '%s/%s.crt\n' "$base" "$domain"
      printf '%s/%s.key\n' "$base" "$domain"
      ;;
  esac
}

# Print the reload command appropriate for this host.
# Order of preference:
#   1. NGINX_RELOAD_CMD from /etc/certease.conf (explicit override).
#   2. `systemctl reload nginx` when a nginx.service unit exists.
#   3. `<nginx_bin> -s reload` using the detected binary — critical on LNMP/BT
#      hosts where /usr/sbin/nginx doesn't exist and bare `nginx` isn't in PATH.
nginx_reload_cmd() {
  if [[ -n "${NGINX_RELOAD_CMD:-}" ]]; then
    printf '%s\n' "$NGINX_RELOAD_CMD"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl list-unit-files 2>/dev/null | grep -q '^nginx\.service'; then
      printf 'systemctl reload nginx\n'
      return 0
    fi
  fi
  local bin
  bin="$(detect_nginx_bin 2>/dev/null || true)"
  if [[ -n "$bin" ]]; then
    printf '%s -s reload\n' "$bin"
  else
    printf 'nginx -s reload\n'
  fi
}
