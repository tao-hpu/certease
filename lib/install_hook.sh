# shellcheck shell=bash
# lib/install_hook.sh — wire every acme.sh domain to our deploy hook.

if [[ -n "${__CERTEASE_HOOK_LOADED:-}" ]]; then
  return 0
fi
__CERTEASE_HOOK_LOADED=1

# Ensure every acme.sh domain has Le_ReloadCmd pointing at our hook and
# --key-file / --fullchain-file pointing into the canonical flavor SSL dir.
#
# Args:
#   $1 = acme.sh home dir
#   $2 = acme.sh binary
#   $3 = nginx flavor (bt|lnmp|std|unknown)
#   $4 = install dir (for hook path)
#   $5 = "dry" for dry-run
ensure_deploy_hooks() {
  local home="$1" bin="$2" flavor="$3" install_dir="$4" mode="${5:-}"
  local hook="$install_dir/hooks/reload-cert.sh"

  if [[ "$flavor" == "unknown" ]]; then
    warn "nginx flavor unknown; skipping deploy-hook install"
    return 0
  fi
  if [[ ! -x "$hook" ]]; then
    warn "Hook not executable: $hook (run: chmod +x $hook)"
    return 1
  fi

  local changed=0 already=0 failed=0
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    local domain is_ecc reload_current
    domain="$(acme_dir_to_domain "$dir")"
    is_ecc=""
    [[ "$(basename "$dir")" == *_ecc ]] && is_ecc="--ecc"

    reload_current="$(acme_conf_get "$dir" Le_ReloadCmd || true)"

    if [[ -n "$reload_current" && "$reload_current" == *"$hook"* ]]; then
      already=$(( already + 1 ))
      debug "$domain already wired to $hook"
      continue
    fi

    # Figure out target cert/key paths for this flavor.
    local crt_path key_path paths
    paths="$(nginx_cert_paths "$flavor" "$domain")" || {
      warn "$domain: cannot resolve cert path for flavor=$flavor; skipping"
      failed=$(( failed + 1 ))
      continue
    }
    crt_path="$(printf '%s\n' "$paths" | sed -n '1p')"
    key_path="$(printf '%s\n' "$paths" | sed -n '2p')"

    if [[ "$mode" == "dry" ]]; then
      log "[dry-run] Would install hook for $domain (fullchain=$crt_path key=$key_path)"
      changed=$(( changed + 1 ))
      continue
    fi

    mkdir -p "$(dirname "$crt_path")" 2>/dev/null || true

    local log_tmp
    log_tmp="$(mktemp)"
    # shellcheck disable=SC2086
    if "$bin" --home "$home" --install-cert -d "$domain" $is_ecc \
        --fullchain-file "$crt_path" \
        --key-file "$key_path" \
        --reloadcmd "$hook" >"$log_tmp" 2>&1; then
      ok "$domain: hook installed → $hook"
      changed=$(( changed + 1 ))
      rm -f "$log_tmp"
    else
      err "$domain: acme.sh --install-cert failed — last line: $(tail -n1 "$log_tmp" 2>/dev/null)"
      rm -f "$log_tmp"
      failed=$(( failed + 1 ))
    fi
  done < <(list_acme_domains "$home")

  log "Deploy hooks: $changed changed, $already already-correct, $failed failed"
  [[ "$failed" -eq 0 ]]
}
