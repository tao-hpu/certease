#!/usr/bin/env bash
# install.sh — thin entry for `curl ... | bash` or direct execution.
# All real logic lives in bin/certease.

set -euo pipefail

SELF="${BASH_SOURCE[0]}"
ROOT="$(cd "$(dirname "$SELF")" && pwd)"

if [[ ! -x "$ROOT/bin/certease" ]]; then
  chmod +x "$ROOT/bin/certease" "$ROOT/hooks/reload-cert.sh" 2>/dev/null || true
fi

exec "$ROOT/bin/certease" install "$@"
