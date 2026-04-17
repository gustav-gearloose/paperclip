#!/bin/sh
set -e

# Capture runtime UID/GID from environment variables, defaulting to 1000
PUID=${USER_UID:-1000}
PGID=${USER_GID:-1000}

# Adjust the node user's UID/GID if they differ from the runtime request
# and fix volume ownership only when a remap is needed
changed=0

if [ "$(id -u node)" -ne "$PUID" ]; then
    echo "Updating node UID to $PUID"
    usermod -o -u "$PUID" node
    changed=1
fi

if [ "$(id -g node)" -ne "$PGID" ]; then
    echo "Updating node GID to $PGID"
    groupmod -o -g "$PGID" node
    usermod -g "$PGID" node
    changed=1
fi

if [ "$changed" = "1" ]; then
    chown -R node:node /paperclip
fi

# ── Gearloose bootstrap hook ──────────────────────────────────────────────────
# If PAPERCLIP_SAAS_CALLBACK_URL is set, run bootstrap-ceo on first boot and
# POST the invite URL back to the saas backend. This enables fully automated
# customer provisioning without SSH access.
#
# The server must start first so config.json gets written by its own onboard
# logic. We start it in the background, wait for config.json, run bootstrap,
# then let the server keep running in the foreground.
# ─────────────────────────────────────────────────────────────────────────────

PAPERCLIP_HOME="${PAPERCLIP_HOME:-/paperclip}"
BOOTSTRAP_DONE="$PAPERCLIP_HOME/instances/default/.gearloose_bootstrap_done"

if [ -n "$PAPERCLIP_SAAS_CALLBACK_URL" ] && [ ! -f "$BOOTSTRAP_DONE" ]; then
    echo "[gearloose] Bootstrap mode — starting server in background..."

    # Start server as the node user in background
    gosu node "$@" &
    SERVER_PID=$!

    CONFIG_FILE="$PAPERCLIP_HOME/instances/default/config.json"
    echo "[gearloose] Waiting for config.json (max 120s)..."
    ELAPSED=0
    while [ ! -f "$CONFIG_FILE" ] && [ $ELAPSED -lt 120 ]; do
        sleep 3
        ELAPSED=$((ELAPSED + 3))
    done

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[gearloose] ERROR: config.json not found after 120s — skipping bootstrap"
    else
        echo "[gearloose] config.json found, running bootstrap-ceo..."
        INVITE_OUTPUT=$(gosu node sh -c "cd /app && pnpm paperclipai auth bootstrap-ceo 2>&1") || true
        INVITE_URL=$(echo "$INVITE_OUTPUT" | grep -o 'http[s]*://[^ ]*' | tail -1)

        if [ -n "$INVITE_URL" ]; then
            echo "[gearloose] Bootstrap succeeded, POSTing invite URL to saas..."
            curl -sf -X POST "$PAPERCLIP_SAAS_CALLBACK_URL" \
                -H "Content-Type: application/json" \
                -d "{\"invite_url\": \"$INVITE_URL\", \"instance_token\": \"${PAPERCLIP_INSTANCE_TOKEN:-}\"}" \
                && touch "$BOOTSTRAP_DONE" \
                && echo "[gearloose] Callback sent OK" \
                || echo "[gearloose] WARNING: callback POST failed — invite URL was: $INVITE_URL"
        else
            echo "[gearloose] WARNING: bootstrap-ceo produced no URL. Output was:"
            echo "$INVITE_OUTPUT"
        fi
    fi

    # Hand off — wait for the server process we already started
    wait $SERVER_PID
else
    # Normal start (no callback URL, or already bootstrapped)
    exec gosu node "$@"
fi
