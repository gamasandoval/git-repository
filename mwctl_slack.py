# -*- coding: utf-8 -*-
"""
mwctl Slack Bot (Socket Mode + /mwctl)

Behavior:
- If the command does NOT include --exec or --exec-tty -> RAW only (no dashboard).
- If the command includes --exec or --exec-tty:
    - For `status` -> Pretty dashboard (2 blocks like screenshot).
    - For other commands -> RAW.
- If the user adds --raw -> always RAW.

Other:
- Runs mwctl via: /usr/bin/bash -lc "<mwctl ...>" to mimic an interactive shell.
- Forces HOME=/home/mobaxterm so ~/.ssh/config and keys are found.
- Strips ANSI sequences before sending to Slack.
- Prepends header context to RAW output when available.
"""

import os
import shlex
import subprocess
import logging
import re
from typing import Dict, Any, List, Tuple, Optional

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler


# ---------------- Logging ----------------
logging.basicConfig(level=logging.INFO)
log = logging.getLogger("mwctl-slack")


# ---------------- Config ----------------
BOT_TOKEN = os.environ["SLACK_BOT_TOKEN"]
APP_TOKEN = os.environ["SLACK_APP_TOKEN"]

MWCTL_BIN = os.environ.get("MWCTL_BIN", "/home/mobaxterm/BOX/Code/mwbot/bin/mwctl")
MWCTL_HOME = os.environ.get("MWCTL_HOME", "/home/mobaxterm")

try:
    TIMEOUT = int(os.environ.get("MWCTL_TIMEOUT", "30"))
except ValueError:
    TIMEOUT = 30

ALLOWED_CMDS = {"info", "status", "logs", "journal", "url", "restart"}
BOT_FLAGS = {"--raw"}

app = App(token=BOT_TOKEN)


# ---------------- Helpers ----------------
def strip_ansi(text: str) -> str:
    ansi_escape = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
    return ansi_escape.sub("", text or "")


def normalize_state(state: str) -> str:
    s = (state or "").strip().upper()
    if s in ("RUNNING", "ACTIVE"):
        return "RUNNING"
    if s in ("STOPPED", "INACTIVE", "DEAD"):
        return "STOPPED"
    if s in ("FAILED", "DOWN", "ERROR"):
        return "FAILED"
    return s or "UNKNOWN"


def state_badge(state: str) -> str:
    st = normalize_state(state)
    if st == "RUNNING":
        return "🟢"
    if st in ("STOPPED", "FAILED"):
        return "🔴"
    if st in ("DEGRADED", "WARNING"):
        return "🟡"
    return "⚪"


def build_bash_login_command(parts: List[str]) -> List[str]:
    cmd_str = "{} {}".format(
        shlex.quote(MWCTL_BIN),
        " ".join(shlex.quote(p) for p in parts),
    ).strip()
    return ["/usr/bin/bash", "-lc", cmd_str]


def split_flags(parts: List[str]) -> Tuple[List[str], List[str], List[str]]:
    core: List[str] = []
    mwctl_flags: List[str] = []
    bot_flags: List[str] = []

    for p in parts:
        if p.startswith("--"):
            if p in BOT_FLAGS:
                bot_flags.append(p)
            else:
                mwctl_flags.append(p)  # pass-through
        else:
            core.append(p)

    return core, mwctl_flags, bot_flags


def parse_status_details(output: str) -> Dict[str, str]:
    clean = strip_ansi(output)
    lines = [ln.rstrip() for ln in clean.splitlines()]

    info: Dict[str, str] = {}

    header_patterns = [
        ("Client", r"^\s*Client\s*:\s*(.+)\s*$"),
        ("Host", r"^\s*Host\s*:\s*(.+)\s*$"),
        ("Env", r"^\s*Env\s*:\s*(.+)\s*$"),
        ("App", r"^\s*App\s*:\s*(.+)\s*$"),
        ("Service", r"^\s*Service\s*:\s*(.+)\s*$"),
        ("RunAs", r"^\s*RunAs\s*:\s*(.+)\s*$"),
    ]
    compiled = [(k, re.compile(p)) for k, p in header_patterns]

    for ln in lines:
        for key, rx in compiled:
            m = rx.match(ln)
            if m and key not in info:
                info[key] = m.group(1).strip()

    # Active line parsing
    active_line = ""
    for ln in lines:
        if ln.strip().startswith("Active:"):
            active_line = ln.strip()
            break

    state = "UNKNOWN"
    since = ""
    uptime = ""

    if active_line:
        low = active_line.lower()
        if "active" in low and "running" in low:
            state = "RUNNING"
        elif "inactive" in low or "dead" in low:
            state = "STOPPED"
        elif "failed" in low:
            state = "FAILED"

        if " since " in active_line:
            tail = active_line.split(" since ", 1)[1].strip()
            if ";" in tail:
                since_part, uptime_part = tail.split(";", 1)
                since = since_part.strip()
                uptime = uptime_part.strip()
            else:
                since = tail.strip()

    info["State"] = normalize_state(state)
    if since:
        info["Since"] = since
    if uptime:
        info["Uptime"] = uptime

    # Memory
    for ln in lines:
        if ln.strip().startswith("Memory:"):
            info["Memory"] = ln.split(":", 1)[1].strip()
            break

    # Port (best effort)
    port = ""
    for ln in lines:
        if "LISTEN" in ln and ":" in ln:
            m = re.findall(r":(\d{2,5})\b", ln)
            if m:
                port = m[-1]
    if port:
        info["Port"] = port

    return info


def build_blocks_like_image(summary: Dict[str, str]) -> List[Dict[str, Any]]:
    """
    Layout requested (like screenshot):

    Block 1:
      Header: "Status Result"
      Line: "🟢 BEP on it-s-banethos-t (env: TEST)"  -> TEST as plain text (no backticks)
      Next line: "Client: Pearl River Community College"

    Block 2:
      Two-column fields:
        Left:  Service, Uptime, Memory
        Right: State, Since, Port
    """
    client = summary.get("Client", "Unknown")
    host = summary.get("Host", "Unknown")
    env = summary.get("Env", "Unknown")
    app_name = summary.get("App", "Unknown")

    service = summary.get("Service", "Unknown")
    uptime = summary.get("Uptime", "")
    memory = summary.get("Memory", "")
    since = summary.get("Since", "")
    port = summary.get("Port", "")

    state = normalize_state(summary.get("State", "UNKNOWN"))
    icon = state_badge(state)

    # Block 1 text
    top_line = f"{icon} *{app_name}* on *{host}*"
    client_line = f"*Client:* {client}"
    environment_line = f"*Environment:* {env}"

    blocks: List[Dict[str, Any]] = [
        {"type": "header", "text": {"type": "plain_text", "text": "Status Result", "emoji": True}},
        {
            "type": "section",
            "text": {"type": "mrkdwn", "text": f"{top_line}\n{client_line}\n{environment_line}"},
        },
        {"type": "divider"},
    ]

    # Block 2 fields (2 columns)
    # Slack renders fields in a grid; order matters (left, right, left, right...)
    fields: List[Dict[str, Any]] = []

    def field(label: str, value: str) -> Dict[str, Any]:
        return {"type": "mrkdwn", "text": f"*{label}:*\n{value}"}

    # Row 1
    fields.append(field("Service", f"`{service}`"))
    fields.append(field("State", f"{icon} *{state}*"))

    # Row 2
    if uptime:
        fields.append(field("Uptime", uptime))
    else:
        fields.append(field("Uptime", "—"))
    if since:
        fields.append(field("Since", since))
    else:
        fields.append(field("Since", "—"))

    # Row 3
    if memory:
        fields.append(field("Memory", memory))
    else:
        fields.append(field("Memory", "—"))
    if port:
        fields.append(field("Port", port))
    else:
        fields.append(field("Port", "—"))

    blocks.append({"type": "section", "fields": fields[:10]})
    return blocks


def to_raw_response(text: str, summary: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
    cleaned = strip_ansi(text).strip() or "(no output)"
    cleaned = cleaned[:3900]

    if not summary:
        return {"text": f"```{cleaned}```"}

    client = summary.get("Client", "Unknown")
    host = summary.get("Host", "Unknown")
    env = summary.get("Env", "Unknown")
    app_name = summary.get("App", "Unknown")
    service = summary.get("Service", "Unknown")
    run_as = summary.get("RunAs", "Unknown")
    state = normalize_state(summary.get("State", "UNKNOWN"))
    icon = state_badge(state)

    header = (
        f"{icon} *{client}*  |  *{host}* ({env})  |  *{app_name}*\n"
        f"*Service:* `{service}`  •  *RunAs:* `{run_as}`  •  *Status:* *{state}*"
    )

    return {"text": f"{header}\n```{cleaned}```"}


# ---------------- Core logic ----------------
def run_mwctl(user_text: str) -> Dict[str, Any]:
    parts = shlex.split(user_text)

    if not parts:
        return {
            "text": (
                "Usage:\n"
                "• `/mwctl status PRCC it-s-banethos-t BEP [--exec|--exec-tty]`\n"
                "• `/mwctl journal PRCC it-s-banethos-t BEP --lines 20 --exec`\n"
                "• Add `--raw` to force raw output"
            )
        }

    core, mwctl_flags, bot_flags = split_flags(parts)

    cmd = core[0]
    if cmd not in ALLOWED_CMDS:
        return {"text": f"Subcommand not allowed: `{cmd}`"}

    if len(core) < 4:
        return {
            "text": (
                f"ERROR: `{cmd}` requires `<CLIENT> <HOST|ENV> <APP>`.\n"
                f"Example:\n`/mwctl {cmd} PRCC it-s-banethos-t BEP --exec`"
            )
        }

    exec_mode = ("--exec" in mwctl_flags) or ("--exec-tty" in mwctl_flags)
    force_raw = ("--raw" in bot_flags) or (not exec_mode)

    final_parts = core + mwctl_flags
    bash_cmd = build_bash_login_command(final_parts)
    log.info("Executing: %s", " ".join(bash_cmd))

    env = os.environ.copy()
    env["HOME"] = MWCTL_HOME

    try:
        p = subprocess.run(
            bash_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=TIMEOUT,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return {"text": f"⏱️ mwctl timed out ({TIMEOUT}s)."}
    except Exception as e:
        return {"text": f"🔴 Failed to run mwctl: {e}"}

    combined = ((p.stdout or "") + ("\n" + p.stderr if p.stderr else "")).strip()
    combined_clean = strip_ansi(combined)

    summary = parse_status_details(combined_clean) if cmd == "status" else None

    if p.returncode != 0:
        raw = to_raw_response(combined_clean, summary)["text"]
        return {"text": f"🔴 Exit {p.returncode}\n{raw}"}

    if force_raw:
        return to_raw_response(combined_clean, summary)

    if cmd == "status":
        blocks = build_blocks_like_image(summary or {})
        fallback = (
            f"Status {summary.get('App','')} on {summary.get('Host','')}: {summary.get('State','UNKNOWN')}"
            if summary else "Status Result"
        )
        return {"text": fallback, "blocks": blocks}

    return {"text": f"```{combined_clean[:3900]}```"}


# ---------------- Slack handler ----------------
@app.command("/mwctl")
def handle_mwctl(ack, respond, command):
    ack()
    payload = run_mwctl(command.get("text", ""))
    respond(**payload)


# ---------------- Main ----------------
if __name__ == "__main__":
    log.info("Starting mwctl Slack bot...")
    log.info("MWCTL_BIN=%s", MWCTL_BIN)
    log.info("MWCTL_HOME=%s", MWCTL_HOME)
    log.info("MWCTL_TIMEOUT=%s", TIMEOUT)
    SocketModeHandler(app, APP_TOKEN).start()
