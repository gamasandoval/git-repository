#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INV_DIR="$ROOT_DIR/inventory"

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
cat <<EOF
Usage:
  mwctl status  <CLIENT> <HOST> <APP> [--exec|--exec-tty]
  mwctl logs    <CLIENT> <HOST> <APP> <logname> [--lines N] [--filter REGEX] [--exec|--exec-tty]
  mwctl journal <CLIENT> <HOST> <APP> [--lines N] [--exec|--exec-tty]
  mwctl url     <CLIENT> <HOST> <APP> [--exec|--exec-tty]
  mwctl info    <CLIENT> <HOST> <APP>
  mwctl restart <CLIENT> <HOST> <APP>     # executes if --exec/--exec-tty provided

Notes:
  --exec      non-interactive (sudo -n). Will fail if sudo needs password.
  --exec-tty  interactive (ssh -t). Output is streamed so sudo prompt is visible immediately.

EOF
}

[[ $# -lt 1 ]] && usage && exit 1
CMD="$1"; shift || true
[[ $# -ge 3 ]] || { usage; exit 1; }

CLIENT="$(echo "$1" | tr '[:upper:]' '[:lower:]')"; shift
HOST="$1"; shift
APP="$1"; shift

INV_FILE="$INV_DIR/${CLIENT}.json"
[[ -f "$INV_FILE" ]] || die "Inventory not found: $INV_FILE"

jq -e ".hosts[\"$HOST\"]" "$INV_FILE" >/dev/null || die "Host '$HOST' not found"
jq -e ".hosts[\"$HOST\"].apps[\"$APP\"]" "$INV_FILE" >/dev/null || die "App '$APP' not found"

SERVICE_UNIT="$(jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.service_unit" "$INV_FILE")"
BASE_DIR="$(jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.base_dir" "$INV_FILE")"
PORT="$(jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.port" "$INV_FILE")"
RUN_AS_USER="$(jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.run_as_user // empty" "$INV_FILE")"
ENVIRONMENT="$(jq -r ".hosts[\"$HOST\"].environment" "$INV_FILE")"
CLIENT_NAME="$(jq -r ".client_name" "$INV_FILE")"

header() {
  echo "--------------------------------------------"
  echo "Client : $CLIENT_NAME"
  echo "Host   : $HOST"
  echo "Env    : $ENVIRONMENT"
  echo "App    : $APP"
  echo "Service: $SERVICE_UNIT"
  echo "RunAs  : ${RUN_AS_USER:-<none>}"
  echo "--------------------------------------------"
  echo
}

# exec flags (must be last arg)
EXEC_MODE="print"
last="${*: -1}"
if [[ "$last" == "--exec" ]]; then
  EXEC_MODE="exec"
  set -- "${@:1:$(($#-1))}"
elif [[ "$last" == "--exec-tty" ]]; then
  EXEC_MODE="exec_tty"
  set -- "${@:1:$(($#-1))}"
fi

SSH_TARGET="${MW_SSH_TARGET:-$HOST}"
SSH_OPTS=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=2
  -o LogLevel=ERROR
)

run_ssh() {
  local cmd="$1"
  local wrapped="export SYSTEMD_PAGER=cat; export PAGER=cat; $cmd"
  if [[ "$EXEC_MODE" == "exec_tty" ]]; then
    ssh -t "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -lc $(printf '%q' "$wrapped")"
  else
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "bash -lc $(printf '%q' "$wrapped")"
  fi
}

sudo_hint() {
  echo "Sudo needs a password. Use --exec-tty (interactive) or run manually."
}

wrap_sudo() {
  local cmd="$1"
  if [[ "$EXEC_MODE" == "exec" ]]; then
    echo "sudo -n $cmd"
  else
    echo "sudo -p \"[sudo] password for %u: \" $cmd"
  fi
}

wrap_runas_with_validate() {
  local cmd="$1"
  [[ -n "$RUN_AS_USER" ]] || die "run_as_user not defined for this app"

  if [[ "$EXEC_MODE" == "exec" ]]; then
    echo "sudo -n -v && sudo -n -iu $RUN_AS_USER bash -lc $(printf '%q' "$cmd")"
  else
    echo "sudo -p \"[sudo] password for %u: \" -v && sudo -p \"[sudo] password for %u: \" -iu $RUN_AS_USER bash -lc $(printf '%q' "$cmd")"
  fi
}

# Core executor:
# - print: just show the command
# - exec_tty: stream output live (do not capture) so sudo prompt is visible immediately
# - exec: capture output to detect sudo password-required error
exec_or_print() {
  local remote_cmd="$1"

  if [[ "$EXEC_MODE" == "print" ]]; then
    header
    echo "Run on server:"
    echo "  $remote_cmd"
    return 0
  fi

  header
  echo "Executing via SSH on: $SSH_TARGET"
  echo

  if [[ "$EXEC_MODE" == "exec_tty" ]]; then
    run_ssh "$remote_cmd"
    return $?
  fi

  local out=""
  if ! out="$(run_ssh "$remote_cmd" 2>&1)"; then
    if echo "$out" | grep -qiE "sudo:.*password is required|sudo:.*terminal is required|a password is required"; then
      sudo_hint
      echo
    fi
    echo "$out"
    return 1
  fi

  # even if exit 0, sometimes sudo prints password required and later commands continue
  if echo "$out" | grep -qiE "sudo:.*password is required|a password is required"; then
    sudo_hint
    echo
    echo "$out"
    return 1
  fi

  echo "$out"
}

status_cmd() {
  local cmd_nosudo="systemctl status $SERVICE_UNIT --no-pager; echo; systemctl is-active $SERVICE_UNIT"
  local cmd_sudo="$(wrap_sudo "systemctl status $SERVICE_UNIT --no-pager"); echo; $(wrap_sudo "systemctl is-active $SERVICE_UNIT")"
  local port_check="ss -lntp 2>/dev/null | grep $PORT || true"

  if [[ "$EXEC_MODE" == "print" ]]; then
    header
    echo "Try:"
    echo "  $cmd_nosudo"
    echo
    echo "If permission denied:"
    echo "  $cmd_sudo"
    echo
    echo "Port check:"
    echo "  $port_check"
    return 0
  fi

  header
  echo "Executing via SSH on: $SSH_TARGET"
  echo
  echo "(1) Trying without sudo..."
  echo

  if [[ "$EXEC_MODE" == "exec_tty" ]]; then
    # stream: try no-sudo; if it fails, continue with sudo (still streamed)
    if run_ssh "$cmd_nosudo"; then
      echo
      echo "(Port check)"
      run_ssh "$port_check" || true
      return 0
    fi
    echo
    echo "(2) Fallback to sudo..."
    echo
    run_ssh "$cmd_sudo"
    echo
    echo "(Port check)"
    run_ssh "$port_check" || true
    return 0
  fi

  # exec (non-interactive): capture to detect failure
  local out=""
  if out="$(run_ssh "$cmd_nosudo" 2>&1)"; then
    echo "$out"
    echo
    run_ssh "$port_check" || true
    return 0
  fi

  echo "$out"
  echo
  echo "(2) Fallback to sudo..."
  echo
  exec_or_print "$cmd_sudo; echo; $port_check"
}

case "$CMD" in
  status)
    status_cmd
    ;;

  logs)
    [[ $# -ge 1 ]] || die "Missing <logname>"
    LOGNAME="$1"; shift || true

    LINES=200
    FILTER=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --lines) shift; LINES="$1" ;;
        --filter) shift; FILTER="$1" ;;
        *) die "Unknown option $1" ;;
      esac
      shift || true
    done

    LOGPATH="$(jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.logs[\"$LOGNAME\"] // empty" "$INV_FILE")"
    [[ -n "$LOGPATH" ]] || die "Log '$LOGNAME' not found"

    if [[ -n "$RUN_AS_USER" ]]; then
      if [[ -n "$FILTER" ]]; then
        exec_or_print "$(wrap_runas_with_validate "tail -n $LINES $LOGPATH | egrep -i \"$FILTER\" || true")"
      else
        exec_or_print "$(wrap_runas_with_validate "tail -n $LINES $LOGPATH")"
      fi
    else
      # fallback: root sudo
      if [[ -n "$FILTER" ]]; then
        exec_or_print "$(wrap_sudo "tail -n $LINES $LOGPATH") | egrep -i \"$FILTER\" || true"
      else
        exec_or_print "$(wrap_sudo "tail -n $LINES $LOGPATH")"
      fi
    fi
    ;;

  journal)
    LINES=200
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --lines) shift; LINES="$1" ;;
        *) die "Unknown option $1" ;;
      esac
      shift || true
    done

    if [[ -n "$RUN_AS_USER" ]]; then
      exec_or_print "$(wrap_runas_with_validate "journalctl -u $SERVICE_UNIT -n $LINES --no-pager")"
    else
      exec_or_print "$(wrap_sudo "journalctl -u $SERVICE_UNIT -n $LINES --no-pager")"
    fi
    ;;

  url)
    URL="$(jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.url" "$INV_FILE")"
    [[ "$URL" == "null" || -z "$URL" ]] && { header; echo "No URL defined."; exit 0; }

    STATUS_CMD="curl -s -o /dev/null -w \"%{http_code} %{time_total}\" -m 10 \"$URL\""

    if [[ "$EXEC_MODE" == "print" ]]; then
      header
      echo "URL:"
      echo "  $URL"
      echo
      echo "Test from server:"
      echo "  curl -s -o /dev/null -w \"%{http_code} %{time_total}\" -m 10 \"$URL\""
      exit 0
    fi

    header
    echo "Executing via SSH on: $SSH_TARGET"
    echo

    STATUS_OUT="$(run_ssh "$STATUS_CMD" 2>&1)" || {
      echo "URL: $URL | ERROR: $STATUS_OUT"
      exit 1
    }

    HTTP_CODE="$(echo "$STATUS_OUT" | awk '{print $1}')"
    TIME_TOTAL="$(echo "$STATUS_OUT" | awk '{print $2}')"

    # Detect if terminal supports color
if [[ -t 1 ]]; then
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[0;33m'
  RED=$'\033[0;31m'
  NC=$'\033[0m'
else
  GREEN=""
  YELLOW=""
  RED=""
  NC=""
fi


    if [[ "$HTTP_CODE" =~ ^[0-9]+$ ]]; then
      if [[ "$HTTP_CODE" -ge 200 && "$HTTP_CODE" -lt 300 ]]; then
        COLOR="$GREEN"
      elif [[ "$HTTP_CODE" -ge 300 && "$HTTP_CODE" -lt 400 ]]; then
        COLOR="$YELLOW"
      else
        COLOR="$RED"
      fi
      echo "URL: $URL | ${COLOR}Status code: $HTTP_CODE${NC} | Time: ${TIME_TOTAL}s"
    else
      echo "URL: $URL | ERROR: $STATUS_OUT"
      exit 1
    fi
    ;;



  restart)
    if [[ "$EXEC_MODE" == "print" ]]; then
      header
      echo "Restart (manual):"
      echo "  sudo systemctl restart $SERVICE_UNIT"
      echo
      echo "Verify:"
      echo "  sudo systemctl is-active $SERVICE_UNIT"
      echo "  ss -lntp | grep $PORT"
      exit 0
    fi

    header
    echo "Executing restart via SSH on: $SSH_TARGET"
    echo

    RESTART_CMD="$(wrap_sudo "systemctl restart $SERVICE_UNIT")"
    VERIFY_CMD="$(wrap_sudo "systemctl is-active $SERVICE_UNIT"); echo; ss -lntp 2>/dev/null | grep $PORT || true"

    if [[ "$EXEC_MODE" == "exec_tty" ]]; then
      # Stream live
      run_ssh "$RESTART_CMD"
      echo
      echo "Verifying..."
      echo
      run_ssh "$VERIFY_CMD"
      exit $?
    fi

    # Non-interactive exec
    local out=""
    if ! out="$(run_ssh "$RESTART_CMD" 2>&1)"; then
      if echo "$out" | grep -qiE "sudo:.*password is required|sudo:.*terminal is required|a password is required"; then
        sudo_hint
        echo
      fi
      echo "$out"
      exit 1
    fi

    echo "$out"
    echo
    echo "Verifying..."
    echo
    run_ssh "$VERIFY_CMD"
    ;;

  info)
    header
    echo "Base Dir : $BASE_DIR"
    echo "Port     : $PORT"
    echo "Run As   : ${RUN_AS_USER:-not defined}"
    echo
    echo "Available logs:"
    jq -r ".hosts[\"$HOST\"].apps[\"$APP\"].tomcat.logs | keys[]" "$INV_FILE" | sed 's/^/  - /'
    ;;

  *)
    usage
    ;;
esac

