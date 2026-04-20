# shellcheck shell=bash
# lib/status.sh — enumerate all certs (acme.sh + certbot) and print a days-left table.

if [[ -n "${__CERTEASE_STATUS_LOADED:-}" ]]; then
  return 0
fi
__CERTEASE_STATUS_LOADED=1

# Extract notAfter from a PEM file as epoch seconds. Empty on failure.
_cert_not_after_epoch() {
  local pem="$1"
  [[ -f "$pem" ]] || return 1
  local raw
  raw="$(openssl x509 -in "$pem" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')"
  [[ -z "$raw" ]] && return 1
  date_to_epoch "$raw"
}

# Extract issuer CN from a PEM file. Empty on failure.
_cert_issuer() {
  local pem="$1"
  [[ -f "$pem" ]] || return 1
  openssl x509 -in "$pem" -noout -issuer 2>/dev/null \
    | sed -E 's/.*CN ?= ?([^,\/]+).*/\1/' \
    | sed 's/[[:space:]]*$//'
}

# Populate three parallel arrays from acme.sh domains:
#   STATUS_TOOL STATUS_DOMAIN STATUS_CA STATUS_NOT_AFTER_EPOCH
_collect_acme_rows() {
  local home="$1"
  [[ -d "$home" ]] || return 0
  local dir domain cer epoch issuer
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    domain="$(acme_dir_to_domain "$dir")"
    # Prefer the leaf cert (named after the domain). Fall back to fullchain.cer
    # (openssl reads only the first cert in a chain, which is the leaf).
    # Never pick ca.cer — that's the intermediate and would report the wrong expiry.
    if [[ -f "$dir/$domain.cer" ]]; then
      cer="$dir/$domain.cer"
    elif [[ -f "$dir/fullchain.cer" ]]; then
      cer="$dir/fullchain.cer"
    else
      cer="$(find "$dir" -maxdepth 1 -name '*.cer' ! -name 'ca.cer' ! -name '*.csr.*' | head -n1)"
    fi
    [[ -z "$cer" || ! -f "$cer" ]] && continue
    epoch="$(_cert_not_after_epoch "$cer" || true)"
    issuer="$(_cert_issuer "$cer" || true)"
    STATUS_TOOL+=("acme.sh")
    STATUS_DOMAIN+=("$domain")
    STATUS_CA+=("${issuer:-unknown}")
    STATUS_NOT_AFTER_EPOCH+=("${epoch:-0}")
  done < <(list_acme_domains "$home")
}

_collect_certbot_rows() {
  local live_dir="/etc/letsencrypt/live"
  [[ -d "$live_dir" ]] || return 0
  local d domain pem epoch issuer
  for d in "$live_dir"/*/; do
    [[ -d "$d" ]] || continue
    domain="$(basename "$d")"
    [[ "$domain" == "README" ]] && continue
    pem="$d/fullchain.pem"
    [[ -f "$pem" ]] || continue
    epoch="$(_cert_not_after_epoch "$pem" || true)"
    issuer="$(_cert_issuer "$pem" || true)"
    STATUS_TOOL+=("certbot")
    STATUS_DOMAIN+=("$domain")
    STATUS_CA+=("${issuer:-unknown}")
    STATUS_NOT_AFTER_EPOCH+=("${epoch:-0}")
  done
}

# Print the status table. Returns exit code:
#   0 if all OK, 1 if any WARN, 2 if any CRITICAL.
print_status_table() {
  load_config
  local home
  home="$(detect_acme_home || true)"

  STATUS_TOOL=()
  STATUS_DOMAIN=()
  STATUS_CA=()
  STATUS_NOT_AFTER_EPOCH=()

  [[ -n "$home" ]] && _collect_acme_rows "$home"
  _collect_certbot_rows

  local n="${#STATUS_DOMAIN[@]}"
  if [[ "$n" -eq 0 ]]; then
    warn "No certificates found (no acme.sh domains and no certbot live dir)."
    return 1
  fi

  printf '%-8s %-32s %-18s %-13s %-5s %s\n' \
    "TOOL" "DOMAIN" "CA" "NOT_AFTER" "DAYS" "STATUS"

  local worst=0
  local i
  for (( i = 0; i < n; i++ )); do
    local tool="${STATUS_TOOL[$i]}"
    local domain="${STATUS_DOMAIN[$i]}"
    local ca="${STATUS_CA[$i]}"
    local epoch="${STATUS_NOT_AFTER_EPOCH[$i]}"

    local not_after days status color
    if [[ "$epoch" == "0" || -z "$epoch" ]]; then
      not_after="?"
      days="?"
      status="UNKNOWN"
      color="$C_YELLOW"
      [[ "$worst" -lt 1 ]] && worst=1
    else
      not_after="$(date -u -r "$epoch" +%Y-%m-%d 2>/dev/null || date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null || echo "?")"
      days="$(days_until "$epoch")"
      if (( days < CRITICAL_DAYS )); then
        status="CRITICAL"
        color="$C_RED"
        worst=2
      elif (( days < WARN_DAYS )); then
        status="WARN"
        color="$C_YELLOW"
        [[ "$worst" -lt 1 ]] && worst=1
      else
        status="OK"
        color="$C_GREEN"
      fi
    fi

    printf '%-8s %-32s %-18s %-13s %-5s %s%s%s\n' \
      "$tool" "$domain" "$ca" "$not_after" "$days" "$color" "$status" "$C_RESET"
  done

  return "$worst"
}
