# -*- coding: utf-8 -*-
"""
AppPilot Slack Bot (Socket Mode + Slash Command)

Behavior:
- If the command does NOT include --exec or --exec-tty -> RAW only.
- If includes --exec or --exec-tty:
    - For `status` -> Pretty dashboard.
    - Others -> RAW.
- If --raw is present -> always RAW.

Branding configurable via environment variables.
"""

import os
import shlex
import subprocess
import logging
import re
import shutil
from typing import Dict, Any, List, Tuple, Optional

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler


# ---------------- Logging ----------------
logging.basicConfig(level=logging.INFO)
log = logging.getLogger("apppilot-slack")


# ---------------- Required Slack Tokens ----------------
BOT_TOKEN = os.environ["SLACK_BOT_TOKEN"]
APP_TOKEN = os.environ["SLACK_APP_TOKEN"]

app = App(token=BOT_TOKEN)


# ---------------- Branding / Config ----------------
APP_BRAND = os.environ.get("APP_BRAND", "AppPilot")
SLASH_CMD = os.environ.get("SLASH_CMD", "/appctl").strip()

APPCTL_BIN_DEFAULT = "/home/mobaxterm/BOX/Code/slackbot/bin/appctl"
APPCTL_BIN = os.environ.get("APPCTL_BIN", APPCTL_BIN_DEFAULT)

# Python 3.7 compatible CTL_BIN detection
CTL_BIN = os.environ.get("CTL_BIN", "").strip()

if not CTL_BIN:
    if shutil.which("appctl"):
        CTL_BIN = "appctl"
    else:
        CTL_BIN = APPCTL_BIN

CTL_HOME = os.environ.get("CTL_HOME", os.environ.get("APPCTL_HOME", "/home/mobaxterm"))

try:
    TIMEOUT = int(os.environ.get("CTL_TIMEOUT", os.environ.get("APPCTL_TIMEOUT", "30")))
except ValueError:
    TIMEOUT = 30

ALLOWED_CMDS = {"info", "status", "logs", "journal", "url", "stop", "start", "restart" }
BOT_FLAGS = {"--raw"}


# ---------------- Helpers ----------------
def strip_ansi(text):
    ansi_escape = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
    return ansi_escape.sub("", text or "")


def normalize_state(state):
    s = (state or "").strip().upper()
    if s in ("RUNNING", "ACTIVE"):
        return "RUNNING"
    if s in ("STOPPED", "INACTIVE", "DEAD"):
        return "STOPPED"
    if s in ("FAILED", "DOWN", "ERROR"):
        return "FAILED"
    return s or "UNKNOWN"


def state_badge(state):
    st = normalize_state(state)
    if st == "RUNNING":
        return "🟢"
    if st in ("STOPPED", "FAILED"):
        return "🔴"
    if st in ("DEGRADED", "WARNING"):
        return "🟡"
    return "⚪"


def build_bash_login_command(parts):
    cmd_str = "{} {}".format(
        shlex.quote(CTL_BIN),
        " ".join(shlex.quote(p) for p in parts),
    ).strip()
    return ["/usr/bin/bash", "-lc", cmd_str]


def split_flags(parts):
    core = []
    ctl_flags = []
    bot_flags = []

    for p in parts:
        if p.startswith("--"):
            if p in BOT_FLAGS:
                bot_flags.append(p)
            else:
                ctl_flags.append(p)
        else:
            core.append(p)

    return core, ctl_flags, bot_flags


def parse_status_details(output):
    clean = strip_ansi(output)
    lines = [ln.rstrip() for ln in clean.splitlines()]
    info = {}

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
        if "running" in low:
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

    info["State"] = normalize_state(state)
    if since:
        info["Since"] = since
    if uptime:
        info["Uptime"] = uptime

    for ln in lines:
        if ln.strip().startswith("Memory:"):
            info["Memory"] = ln.split(":", 1)[1].strip()

    port = ""
    for ln in lines:
        if "LISTEN" in ln and ":" in ln:
            m = re.findall(r":(\d{2,5})\b", ln)
            if m:
                port = m[-1]
    if port:
        info["Port"] = port

    return info


def build_blocks_like_image(summary):
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

    top_line = "{} *{}* on *{}*".format(icon, app_name, host)
    client_line = "*Client:* {}".format(client)
    environment_line = "*Environment:* {}".format(env)

    blocks = [
        {"type": "header", "text": {"type": "plain_text", "text": "Status Result", "emoji": True}},
        {"type": "section", "text": {"type": "mrkdwn", "text": "{}\n{}\n{}".format(top_line, client_line, environment_line)}},
        {"type": "divider"},
    ]

    fields = []

    def field(label, value):
        return {"type": "mrkdwn", "text": "*{}:*\n{}".format(label, value)}

    fields.append(field("Service", "`{}`".format(service)))
    fields.append(field("State", "{} *{}*".format(icon, state)))
    fields.append(field("Uptime", uptime if uptime else "—"))
    fields.append(field("Since", since if since else "—"))
    fields.append(field("Memory", memory if memory else "—"))
    fields.append(field("Port", port if port else "—"))

    blocks.append({"type": "section", "fields": fields[:10]})
    return blocks


def to_raw_response(text, summary=None):
    cleaned = strip_ansi(text).strip() or "(no output)"
    cleaned = cleaned[:3900]

    if not summary:
        return {"text": "```{}```".format(cleaned)}

    client = summary.get("Client", "Unknown")
    host = summary.get("Host", "Unknown")
    env = summary.get("Env", "Unknown")
    app_name = summary.get("App", "Unknown")
    service = summary.get("Service", "Unknown")
    state = normalize_state(summary.get("State", "UNKNOWN"))
    icon = state_badge(state)

    header = "{} *{}*  |  *{}* ({})  |  *{}*\n*Service:* `{}`  •  *Status:* *{}*".format(
        icon, client, host, env, app_name, service, state
    )

    return {"text": "{}\n```{}```".format(header, cleaned)}


# ---------------- Core logic ----------------
def run_ctl(user_text):
    parts = shlex.split(user_text)

    if not parts:
        return {"text": "{} usage:\n• `{}` status ...".format(APP_BRAND, SLASH_CMD)}

    core, ctl_flags, bot_flags = split_flags(parts)

    cmd = core[0]
    if cmd not in ALLOWED_CMDS:
        return {"text": "Subcommand not allowed: `{}`".format(cmd)}

    if len(core) < 4:
        return {"text": "ERROR: `{}` requires <CLIENT> <HOST|ENV> <APP>".format(cmd)}

    exec_mode = ("--exec" in ctl_flags) or ("--exec-tty" in ctl_flags)
    force_raw = ("--raw" in bot_flags) or (not exec_mode)

    final_parts = core + ctl_flags
    bash_cmd = build_bash_login_command(final_parts)

    env = os.environ.copy()
    env["HOME"] = CTL_HOME

    try:
        p = subprocess.run(
            bash_cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=TIMEOUT,
            env=env,
        )
    except Exception as e:
        return {"text": "Error running {}: {}".format(APP_BRAND, e)}

    combined = ((p.stdout or "") + ("\n" + p.stderr if p.stderr else "")).strip()
    combined_clean = strip_ansi(combined)

    summary = parse_status_details(combined_clean) if cmd == "status" else None

    if p.returncode != 0:
        return {"text": "Exit {}\n{}".format(p.returncode, to_raw_response(combined_clean, summary)["text"])}

    if force_raw:
        return to_raw_response(combined_clean, summary)

    if cmd == "status":
        return {
            "text": "Status",
            "blocks": build_blocks_like_image(summary or {})
        }

    return {"text": "```{}```".format(combined_clean[:3900])}


# ---------------- Slash registration ----------------
def register_commands():
    @app.command(SLASH_CMD)
    def handle_slash(ack, respond, command):
        ack()
        payload = run_ctl(command.get("text", ""))
        respond(**payload)

register_commands()


# ---------------- Main ----------------
if __name__ == "__main__":
    log.info("Starting %s Slack bot...", APP_BRAND)
    log.info("SLASH_CMD=%s", SLASH_CMD)
    log.info("CTL_BIN=%s", CTL_BIN)
    log.info("CTL_HOME=%s", CTL_HOME)
    log.info("TIMEOUT=%s", TIMEOUT)
    SocketModeHandler(app, APP_TOKEN).start()
