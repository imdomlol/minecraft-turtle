#!/usr/bin/env bash
# start-relay.sh -- convenience wrapper to launch the turtle relay server.
#
# Reuses a saved token across restarts (.relay_token, gitignored) instead
# of generating a new one each run -- turtles store whatever token
# remote-setup gave them, and a changed token locks them all out.
#
# Override the token or port explicitly with:
#   RELAY_TOKEN=... RELAY_PORT=... ./start-relay.sh
set -euo pipefail
cd "$(dirname "$0")"

TOKEN_FILE=".relay_token"

if [ -z "${RELAY_TOKEN:-}" ]; then
  if [ -f "$TOKEN_FILE" ]; then
    RELAY_TOKEN="$(cat "$TOKEN_FILE")"
  else
    RELAY_TOKEN="$(openssl rand -hex 24)"
    printf '%s' "$RELAY_TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    echo "generated a new relay token and saved it to $TOKEN_FILE"
  fi
fi
export RELAY_TOKEN

echo "relay token: $RELAY_TOKEN"
echo "(use this in remote-setup on each turtle, and as RELAY_TOKEN for turtlectl.py)"
echo "starting relay on port ${RELAY_PORT:-8787} ..."
exec python3 relay.py
