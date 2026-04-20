# shellcheck shell=bash
# lib/install_cron.sh — ensure acme.sh cron entry + ensure cron output is captured.

if [[ -n "${__CERTEASE_CRON_LOADED:-}" ]]; then
  return 0
fi
__CERTEASE_CRON_LOADED=1

# Ensure root's crontab contains an acme.sh --cron entry whose output is
# redirected to $LOG_DIR/certease-cron.log (not /dev/null).
# Args: $1 = acme.sh home dir, $2 = acme.sh binary path, $3 = "dry" for dry-run.
ensure_acme_cron() {
  local home="$1" bin="$2" mode="${3:-}"
  local log_dir
  log_dir="$(ensure_log_dir)"
  local target_log="$log_dir/certease-cron.log"

  local current
  current="$(crontab -l 2>/dev/null || true)"

  # Case 1: no acme.sh line at all → install cronjob.
  if ! printf '%s\n' "$current" | grep -Fq "acme.sh --cron"; then
    if [[ "$mode" == "dry" ]]; then
      log "[dry-run] Would install acme.sh cron entry (redirect to $target_log)"
      return 0
    fi
    log "Installing acme.sh cron entry via --install-cronjob"
    ( "$bin" --home "$home" --install-cronjob >>"$target_log" 2>&1 ) || {
      warn "acme.sh --install-cronjob failed; see $target_log"
      return 1
    }
    # acme.sh typically writes "> /dev/null" — rewrite to our log.
    _rewrite_cron_redirect "$target_log"
    ok "acme.sh cron entry installed; output → $target_log"
    return 0
  fi

  # Case 2: cron line exists but goes to /dev/null → rewrite it.
  if printf '%s\n' "$current" | grep -E "acme\.sh --cron" | grep -q '/dev/null'; then
    if [[ "$mode" == "dry" ]]; then
      log "[dry-run] Would redirect existing acme.sh cron output to $target_log"
      return 0
    fi
    _rewrite_cron_redirect "$target_log"
    ok "Redirected acme.sh cron output → $target_log"
    return 0
  fi

  ok "acme.sh cron entry already present with logging"
}

# Rewrite any crontab line matching `acme.sh --cron` so its stdout/stderr go to $1.
_rewrite_cron_redirect() {
  local target_log="$1"
  local tmp
  tmp="$(mktemp)"
  crontab -l 2>/dev/null | awk -v L="$target_log" '
    /acme\.sh --cron/ {
      # strip any trailing redirections
      sub(/[ \t]*>>?[ \t]*[^ \t]+([ \t]+2>&1)?[ \t]*$/, "", $0)
      sub(/[ \t]*2>&1[ \t]*$/, "", $0)
      print $0 " >>" L " 2>&1"
      next
    }
    { print }
  ' > "$tmp"
  crontab "$tmp"
  rm -f "$tmp"
}

# Enable LOG_FILE + LOG_LEVEL=1 in acme.sh's account.conf.
# Args: $1 = acme.sh home dir, $2 = "dry" for dry-run.
ensure_acme_logging() {
  local home="$1" mode="${2:-}"
  local conf="$home/account.conf"
  local log_file="$home/acme.sh.log"

  [[ -f "$conf" ]] || {
    warn "account.conf not found at $conf"
    return 1
  }

  local needs_update=0
  if ! grep -E '^LOG_FILE=' "$conf" >/dev/null 2>&1; then
    needs_update=1
  fi
  if ! grep -E '^LOG_LEVEL=' "$conf" >/dev/null 2>&1; then
    needs_update=1
  fi

  if [[ "$needs_update" -eq 0 ]]; then
    ok "acme.sh LOG_FILE + LOG_LEVEL already set in account.conf"
    return 0
  fi

  if [[ "$mode" == "dry" ]]; then
    log "[dry-run] Would enable LOG_FILE=$log_file and LOG_LEVEL=1 in $conf"
    return 0
  fi

  # Remove any commented-out versions, then append canonical lines.
  local tmp
  tmp="$(mktemp)"
  grep -vE '^[[:space:]]*#?[[:space:]]*LOG_(FILE|LEVEL)=' "$conf" > "$tmp" || true
  {
    cat "$tmp"
    printf 'LOG_FILE='\''%s'\''\n' "$log_file"
    printf 'LOG_LEVEL='\''1'\''\n'
  } > "$conf"
  rm -f "$tmp"
  ok "Enabled LOG_FILE + LOG_LEVEL=1 in account.conf"
}

# Ensure ACCOUNT_EMAIL is set in acme.sh's account.conf. Used by acme.sh to
# register with CAs (LE sends cert-expiry warnings to this address).
# Args: $1 = acme.sh home, $2 = desired email, $3 = acme.sh bin (for --register-account), $4 = "dry"
ensure_acme_email() {
  local home="$1" want="$2" bin="$3" mode="${4:-}"
  local conf="$home/account.conf"

  [[ -z "$want" ]] && return 0
  [[ -f "$conf" ]] || { warn "account.conf not found at $conf"; return 1; }

  local current
  current="$(grep -E '^ACCOUNT_EMAIL=' "$conf" | head -n1 | sed -E "s/^ACCOUNT_EMAIL=['\"]?([^'\"]*)['\"]?$/\1/")"

  if [[ "$current" == "$want" ]]; then
    ok "acme.sh ACCOUNT_EMAIL already set to $want"
    return 0
  fi

  if [[ "$mode" == "dry" ]]; then
    log "[dry-run] Would set acme.sh ACCOUNT_EMAIL to $want (was: ${current:-<unset>})"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  grep -vE '^[[:space:]]*#?[[:space:]]*ACCOUNT_EMAIL=' "$conf" > "$tmp" || true
  {
    cat "$tmp"
    printf "ACCOUNT_EMAIL='%s'\n" "$want"
  } > "$conf"
  rm -f "$tmp"
  ok "Set acme.sh ACCOUNT_EMAIL to $want"

  # Best-effort: re-register the account with the CA so the new email reaches them.
  if [[ -n "$bin" ]]; then
    ( "$bin" --home "$home" --update-account --accountemail "$want" >/dev/null 2>&1 ) \
      && ok "Updated acme.sh account registration with CA" \
      || warn "acme.sh --update-account failed (email saved locally; retry manually if needed)"
  fi
}

# Ensure certbot account is registered with the desired email.
# Args: $1 = certbot bin, $2 = desired email, $3 = "dry"
ensure_certbot_email() {
  local bin="$1" want="$2" mode="${3:-}"
  [[ -z "$want" || -z "$bin" ]] && return 0

  # Pick the first active account directory; certbot stores email in regr.json.
  local acct_root="/etc/letsencrypt/accounts"
  [[ -d "$acct_root" ]] || { log "certbot has no accounts yet at $acct_root — skipping email sync"; return 0; }

  local regr current=""
  regr="$(find "$acct_root" -maxdepth 5 -type f -name regr.json 2>/dev/null | head -n1)"
  if [[ -n "$regr" ]]; then
    current="$(grep -oE 'mailto:[^"]*' "$regr" | head -n1 | sed 's|mailto:||')"
  fi

  if [[ "$current" == "$want" ]]; then
    ok "certbot account email already set to $want"
    return 0
  fi

  if [[ "$mode" == "dry" ]]; then
    log "[dry-run] Would run: certbot update_account --email $want (was: ${current:-<unset>})"
    return 0
  fi

  if "$bin" update_account --email "$want" --no-eff-email -n >/dev/null 2>&1; then
    ok "Updated certbot account email to $want"
  else
    warn "certbot update_account failed (is there a registered account?)"
  fi
}
