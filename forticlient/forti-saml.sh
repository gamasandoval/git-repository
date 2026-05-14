#!/usr/bin/env bash
set -euo pipefail

FORTICLIENT_PATH="openfortivpn"

# ---- Load environment file ----
ENV_FILE="/opt/forti-saml/.env"

if [[ -f "$ENV_FILE" ]]; then
  export $(grep -v '^#' "$ENV_FILE" | xargs)
fi

# ---- Parameters ----
VPN_HOST="${1:-}"
VPN_USER="${2:-${VPN_USER:-}}"
TRUSTED_CERT="${3:-${TRUSTED_CERT:-}}"
VPN_PASS="${VPN_PASS:-}"

# ---- Paths ----
TOKEN_FILE="/tmp/forti_saml_token.$$"
PID_FILE="/tmp/openfortivpn.pid"
LOG_DIR="/opt/forti-saml/logs"
LOG_FILE="$LOG_DIR/openfortivpn.log"

mkdir -p "$LOG_DIR"

cleanup() {
  rm -f "$TOKEN_FILE"
}
trap cleanup EXIT

# ---- Validate input ----
if [[ -z "$VPN_HOST" ]]; then
  echo "Usage: forti-saml.sh <vpn_host> [vpn_user] [trusted_cert]"
  exit 1
fi

# ---- Auto-detect trusted cert ----
get_trusted_cert() {
  local host="$1"
  local output
  local cert

  output="$(
    timeout 15 "$FORTICLIENT_PATH" "$host:443" --cookie=dummy 2>&1 || true
  )"

  cert="$(
    echo "$output" \
      | grep -oE '[a-fA-F0-9]{64}' \
      | head -n 1 \
      | tr 'A-F' 'a-f'
  )"

  echo "$cert"
}

if [[ -z "$TRUSTED_CERT" ]]; then
  TRUSTED_CERT="$(get_trusted_cert "$VPN_HOST")"
fi

echo "VPN Host: $VPN_HOST"
echo "VPN User: $VPN_USER"

if [[ -n "$TRUSTED_CERT" ]]; then
  echo "Trusted Cert: $TRUSTED_CERT"
else
  echo "Trusted Cert: not required or not detected"
fi

# ---- Password handling ----
if [[ -z "${VPN_PASS:-}" ]]; then
  echo -n "VPN Password: "
  read -rs VPN_PASS
  echo
else
  echo "Using VPN password from environment."
fi

# ---- Get SAML token ----
echo "Requesting SAML token via Okta MFA..."

VPN_PASS="$VPN_PASS" python3.10 /usr/local/bin/saml_connection.py \
  "$VPN_HOST" \
  "$VPN_USER" \
  "$TOKEN_FILE"

unset VPN_PASS

# ---- Validate token ----
if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "ERROR: SAML token was not generated"
  exit 1
fi

SVPNCOOKIE="$(tr -d '\r\n' < "$TOKEN_FILE")"

if [[ -z "$SVPNCOOKIE" ]]; then
  echo "ERROR: SAML token is empty"
  exit 1
fi

# ---- Start VPN ----
echo "Starting VPN connection in background..."

rm -f "$LOG_FILE"

if [[ -n "$TRUSTED_CERT" ]]; then
  "$FORTICLIENT_PATH" "$VPN_HOST:443" \
    --cookie="$SVPNCOOKIE" \
    --trusted-cert "$TRUSTED_CERT" \
    > "$LOG_FILE" 2>&1 &
else
  "$FORTICLIENT_PATH" "$VPN_HOST:443" \
    --cookie="$SVPNCOOKIE" \
    > "$LOG_FILE" 2>&1 &
fi

VPN_PID=$!
echo "$VPN_PID" > "$PID_FILE"

echo "Waiting for VPN tunnel to be established..."

for i in {1..30}; do
  if grep -q "Tunnel is up and running" "$LOG_FILE"; then
    echo "VPN connected successfully."
    echo "PID: $VPN_PID"
    echo "Logs: $LOG_FILE"
    exit 0
  fi

  if ! kill -0 "$VPN_PID" 2>/dev/null; then
    echo "ERROR: VPN process exited unexpectedly."
    exit 1
  fi

  sleep 1
done

echo "WARNING: VPN did not confirm tunnel in time."

