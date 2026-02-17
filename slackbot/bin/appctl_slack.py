# -*- coding: utf-8 -*-
"""
AppPilot Slack Bot (Socket Mode + Slash Command)

Behavior:
- info -> ALWAYS RAW (inventory output).
- status:
    - if --exec and NOT --raw:
        - multi-host or multi-app -> dashboard
        - single-app -> pretty dashboard
        - componentized app (DegreeWorks) -> component dashboard
    - otherwise -> RAW
- url:
    - if --exec and NOT --raw -> URL dashboard
    - otherwise -> RAW
- --raw forces RAW always.

Important:
- Only tool flags are lifted out of the user's command:
    --exec, --all (ctl/tool flags), and --raw (bot-only)
- Command-specific flags like --lines / --filter / --component MUST keep user order.
"""

import os
import shlex
import subprocess
import logging
import re
import shutil
import time
from typing import Dict, Any, List, Tuple, Optional

from slack_bolt import App
from slack_bolt.adapter.socket_mode import SocketModeHandler


logging.basicConfig(level=logging.INFO)
log = logging.getLogger("apppilot-slack")

BOT_TOKEN = os.environ["SLACK_BOT_TOKEN"]
APP_TOKEN = os.environ["SLACK_APP_TOKEN"]
app = App(token=BOT_TOKEN)

APP_BRAND = os.environ.get("APP_BRAND", "AppPilot")
SLASH_CMD = os.environ.get("SLASH_CMD", "/appctl").strip()

APPCTL_BIN_DEFAULT = "/home/mobaxterm/BOX/Code/slackbot/bin/appctl"
APPCTL_BIN = os.environ.get("APPCTL_BIN", APPCTL_BIN_DEFAULT)

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

ALLOWED_CMDS = {"info", "status", "logs", "journal", "url", "stop", "start", "restart"}

# Bot-only flags (NOT passed to bash)
BOT_FLAGS = {"--raw"}

# Tool/ctl flags that we DO want to lift (order doesn't matter)
CTL_FLAGS = {"--exec", "--all"}


def strip_ansi(text: str) -> str:
    ansi_escape = re.compile(r"\x1B\[[0-?]*[ -/]*[@-~]")
    return ansi_escape.sub("", text or "")


def normalize_state(state: Optional[str]) -> str:
    s = (state or "").strip().upper()
    if s in ("RUNNING", "ACTIVE"):
        return "RUNNING"
    if s in ("STOPPED", "INACTIVE", "DEAD"):
        return "STOPPED"
    if s in ("FAILED", "DOWN", "ERROR"):
        return "FAILED"
    return s or "UNKNOWN"


def state_badge(state: Optional[str]) -> str:
    st = normalize_state(state)
    if st == "RUNNING":
        return "🟢"
    if st in ("STOPPED", "FAILED"):
        return "🔴"
    if st in ("DEGRADED", "WARNING"):
        return "🟡"
    return "⚪"


def is_active_icon(is_active: str) -> str:
    s = (is_active or "").strip().lower()
    if s == "active":
        return "🟢"
    if s in ("inactive", "failed", "dead"):
        return "🔴"
    if s in ("activating", "deactivating", "reloading"):
        return "🟡"
    return "⚪"


def build_usage_text() -> str:
    return (
        f"*{APP_BRAND}* usage:\n"
        f"• `{SLASH_CMD} info <CLIENT> <HOST|ENV> [APP] [--all] [--exec]`\n"
        f"• `{SLASH_CMD} status <CLIENT> <HOST|ENV> [APP] [--all] [--exec]`\n"
        f"• `{SLASH_CMD} status <CLIENT> <HOST|ENV> <APP> --component <COMP> [--exec]`\n"
        f"• `{SLASH_CMD} url <CLIENT> <HOST|ENV> <APP> [--component <COMP>] [--exec]`\n"
        f"• `{SLASH_CMD} restart <CLIENT> <HOST|ENV> <APP> [--component <COMP>] [--all] [--exec]`\n"
        f"• `{SLASH_CMD} logs <CLIENT> <HOST|ENV> <APP> [--component <COMP>] <logname> [--lines N] [--filter REGEX] [--exec]`\n"
        f"• `{SLASH_CMD} journal <CLIENT> <HOST|ENV> <APP> [--component <COMP>] [--lines N] [--exec]`\n"
        f"Flags:\n"
        f"• `--exec` runs via SSH (bash handles execution)\n"
        f"• `--all` target all hosts when <HOST|ENV> is an environment\n"
        f"• `--raw` forces raw output (no dashboard)\n"
    )


def build_bash_login_command(parts: List[str]) -> List[str]:
    cmd_str = "{} {}".format(
        shlex.quote(CTL_BIN),
        " ".join(shlex.quote(p) for p in parts),
    ).strip()
    return ["/usr/bin/bash", "-lc", cmd_str]


def split_flags(parts: List[str]) -> Tuple[List[str], List[str], List[str]]:
    """
    Keep user argument order for command-specific flags like --lines/--filter/--component.
    Only extract:
      - bot_flags: --raw
      - ctl_flags: --exec, --all
    Everything else stays in core IN ORIGINAL ORDER.
    """
    core: List[str] = []
    ctl_flags: List[str] = []
    bot_flags: List[str] = []

    for p in parts:
        if p in BOT_FLAGS:
            bot_flags.append(p)
        elif p in CTL_FLAGS:
            ctl_flags.append(p)
        else:
            core.append(p)

    return core, ctl_flags, bot_flags


def parse_header_details(output: str) -> Dict[str, str]:
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
    return info


def parse_status_details_systemctl(output: str) -> Dict[str, str]:
    """
    Old path: parse `systemctl status` output (Active:, Since, Memory, Port).
    This remains used for Tomcat single-app status (BEP/EMA) and component-only status calls.
    """
    info = parse_header_details(output)
    clean = strip_ansi(output)
    lines = [ln.rstrip() for ln in clean.splitlines()]

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


def build_blocks_like_image(summary: Dict[str, str]) -> List[Dict[str, Any]]:
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

    blocks: List[Dict[str, Any]] = [
        {"type": "header", "text": {"type": "plain_text", "text": "Status Result", "emoji": True}},
        {"type": "section", "text": {"type": "mrkdwn", "text": "{}\n{}\n{}".format(top_line, client_line, environment_line)}},
        {"type": "divider"},
    ]

    def field(label: str, value: str) -> Dict[str, Any]:
        return {"type": "mrkdwn", "text": "*{}:*\n{}".format(label, value)}

    fields: List[Dict[str, Any]] = [
        field("Service", "`{}`".format(service)),
        field("State", "{} *{}*".format(icon, state)),
        field("Uptime", uptime if uptime else "—"),
        field("Since", since if since else "—"),
        field("Memory", memory if memory else "—"),
        field("Port", port if port else "—"),
    ]

    blocks.append({"type": "section", "fields": fields[:10]})
    return blocks


def to_raw_response(text: str, summary: Optional[Dict[str, str]] = None) -> Dict[str, Any]:
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


# ---------- Multi-service status dashboard parsing (legacy ALL apps / host) ----------
def health_icon_from_is_active(state_val: str, listen_val: str) -> str:
    s = (state_val or "").strip().lower()
    l = (listen_val or "").strip().lower()
    if s == "active" and l == "listening":
        return "🟢"
    if s == "active":
        return "🟡"
    if s in ("failed", "inactive", "dead"):
        return "🔴"
    if s in ("activating", "deactivating", "reloading"):
        return "🟡"
    return "⚪"


def parse_status_multi_allapps(output: str) -> List[Dict[str, Any]]:
    text = strip_ansi(output or "")
    lines = [ln.rstrip("\n") for ln in text.splitlines()]

    sections: List[Dict[str, Any]] = []
    cur: Optional[Dict[str, Any]] = None
    cur_app: Optional[Dict[str, Any]] = None

    rx_client = re.compile(r"^\s*Client\s*:\s*(.+)\s*$")
    rx_host = re.compile(r"^\s*Host\s*:\s*(.+)\s*$")
    rx_env = re.compile(r"^\s*Env\s*:\s*(.+)\s*$")
    rx_app = re.compile(r"^\s*APP:\s*(.+)\s*$")
    rx_kv = re.compile(r"^\s{2}([A-Za-z ]+)\s*:\s*(.+)\s*$")

    def flush_app():
        nonlocal cur_app, cur
        if cur and cur_app:
            cur["apps"].append(cur_app)
        cur_app = None

    def flush_section():
        nonlocal cur
        if cur:
            flush_app()
            sections.append(cur)
        cur = None

    for ln in lines:
        m = rx_client.match(ln)
        if m:
            if not cur:
                cur = {"Client": m.group(1).strip(), "Host": "", "Env": "", "apps": []}
            else:
                cur["Client"] = m.group(1).strip()
            continue

        m = rx_host.match(ln)
        if m:
            if not cur:
                cur = {"Client": "", "Host": m.group(1).strip(), "Env": "", "apps": []}
            else:
                cur["Host"] = m.group(1).strip()
            continue

        m = rx_env.match(ln)
        if m:
            if not cur:
                cur = {"Client": "", "Host": "", "Env": m.group(1).strip(), "apps": []}
            else:
                cur["Env"] = m.group(1).strip()
            continue

        m = rx_app.match(ln)
        if m:
            if not cur:
                cur = {"Client": "", "Host": "", "Env": "", "apps": []}
            flush_app()
            cur_app = {"App": m.group(1).strip(), "Service": "", "Port": "", "RunAs": "", "State": "", "Listen": ""}
            continue

        m = rx_kv.match(ln)
        if m and cur_app is not None:
            key = m.group(1).strip().lower()
            val = m.group(2).strip()
            if key.startswith("service"):
                cur_app["Service"] = val
            elif key.startswith("port"):
                cur_app["Port"] = val
            elif key.startswith("run as"):
                cur_app["RunAs"] = val
            elif key.startswith("state"):
                cur_app["State"] = val
            elif key.startswith("listen"):
                cur_app["Listen"] = val
            continue

    flush_section()
    return sections


def build_status_multi_blocks(sections: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    blocks: List[Dict[str, Any]] = []
    first = True

    def trunc(s: str, w: int) -> str:
        s = s or ""
        return s if len(s) <= w else (s[: max(0, w - 1)] + "…")

    for sec in sections:
        client = sec.get("Client") or "Unknown"
        host = sec.get("Host") or "Unknown"
        env = sec.get("Env") or "Unknown"
        apps: List[Dict[str, Any]] = sec.get("apps") or []

        green = yellow = red = gray = 0
        for a in apps:
            icon = health_icon_from_is_active(a.get("State", ""), a.get("Listen", ""))
            if icon == "🟢":
                green += 1
            elif icon == "🟡":
                yellow += 1
            elif icon == "🔴":
                red += 1
            else:
                gray += 1

        summary_line = f"🟢 {green}   🟡 {yellow}   🔴 {red}   ⚪ {gray}"

        if not first:
            blocks.append({"type": "divider"})
        first = False

        blocks.append({"type": "header", "text": {"type": "plain_text", "text": f"Environment Status — {host} ({env})", "emoji": True}})
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*Client:* {client}  •  *Services:* {len(apps)}\n{summary_line}"}})

        rows: List[str] = []
        rows.append("HEALTH  APP               PORT   LISTEN        SERVICE")
        rows.append("------  ----------------  -----  ------------  ------------------------------")

        for a in apps:
            icon = health_icon_from_is_active(a.get("State", ""), a.get("Listen", ""))
            appn = trunc(a.get("App", ""), 16).ljust(16)
            port = trunc(a.get("Port", ""), 5).ljust(5)
            listen = trunc(a.get("Listen", ""), 12).ljust(12)
            svc = trunc(a.get("Service", ""), 30)
            rows.append(f"{icon:<6}  {appn}  {port}  {listen}  {svc}")

        table = "```" + "\n".join(rows[:120]) + "```"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": table}})

    return blocks


# ---------- NEW: Componentized app status parsing (DegreeWorks style) ----------
def split_host_runs(output: str) -> List[str]:
    text = strip_ansi(output or "")
    if "Running on host:" not in text:
        return [text]

    parts = re.split(r"(?m)^\s*=+\s*\n\s*Running on host:\s*.*\n\s*=+\s*$", text)
    chunks = [p.strip() for p in parts if p.strip()]
    return chunks or [text]


def parse_component_status_section(section_text: str) -> Optional[Dict[str, Any]]:
    if "Component:" not in section_text and "Main-State:" not in section_text:
        return None

    hdr = parse_header_details(section_text)
    rows: List[Dict[str, str]] = []

    # Main row
    main_state = ""
    for ln in section_text.splitlines():
        m = re.match(r"^\s*Main-State:\s*(.+)\s*$", ln)
        if m:
            main_state = m.group(1).strip()
            break

    service_unit = hdr.get("Service", "")
    if service_unit or main_state:
        rows.append({"Name": "MAIN", "Unit": service_unit or "", "State": (main_state or "").strip()})

    # Component rows
    cur_name = ""
    cur_state = ""
    cur_unit = ""

    def flush():
        nonlocal cur_name, cur_state, cur_unit
        if cur_name:
            rows.append({"Name": cur_name, "Unit": cur_unit, "State": cur_state})
        cur_name, cur_state, cur_unit = "", "", ""

    for ln in section_text.splitlines():
        m = re.match(r"^\s*Component:\s*(.+)\s*$", ln)
        if m:
            flush()
            cur_name = m.group(1).strip()
            continue
        m = re.match(r"^\s*State:\s*(.+)\s*$", ln)
        if m and cur_name:
            cur_state = m.group(1).strip()
            continue
        m = re.match(r"^\s*Unit\s*:\s*(.+)\s*$", ln)
        if m and cur_name:
            cur_unit = m.group(1).strip()
            continue

    flush()

    if not rows:
        return None

    return {
        "Client": hdr.get("Client", "Unknown"),
        "Host": hdr.get("Host", "Unknown"),
        "Env": hdr.get("Env", "Unknown"),
        "App": hdr.get("App", "Unknown"),
        "rows": rows,
    }


def build_component_status_blocks(sections: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    blocks: List[Dict[str, Any]] = []
    first = True

    def trunc(s: str, w: int) -> str:
        s = s or ""
        return s if len(s) <= w else (s[: max(0, w - 1)] + "…")

    for sec in sections:
        client = sec.get("Client", "Unknown")
        host = sec.get("Host", "Unknown")
        env = sec.get("Env", "Unknown")
        appn = sec.get("App", "Unknown")
        rows = sec.get("rows", [])

        green = yellow = red = gray = 0
        for r in rows:
            icon = is_active_icon(r.get("State", ""))
            if icon == "🟢":
                green += 1
            elif icon == "🟡":
                yellow += 1
            elif icon == "🔴":
                red += 1
            else:
                gray += 1

        summary_line = f"🟢 {green}   🟡 {yellow}   🔴 {red}   ⚪ {gray}"

        if not first:
            blocks.append({"type": "divider"})
        first = False

        blocks.append({"type": "header", "text": {"type": "plain_text", "text": f"{appn} — {host} ({env})", "emoji": True}})
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*Client:* {client}  •  *Units:* {len(rows)}\n{summary_line}"}})

        table_rows: List[str] = []
        table_rows.append("STATE  COMPONENT            UNIT")
        table_rows.append("-----  -------------------  ----------------------------------------")

        for r in rows[:120]:
            icon = is_active_icon(r.get("State", ""))
            name = trunc(r.get("Name", ""), 19).ljust(19)
            unit = trunc(r.get("Unit", ""), 40)
            table_rows.append(f"{icon:<5}  {name}  {unit}")

        table = "```" + "\n".join(table_rows) + "```"
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": table}})

    return blocks


# ---------- URL dashboard ----------
def parse_url_result(output: str) -> Tuple[str, str, str]:
    url = ""
    http = ""
    t = ""
    for ln in strip_ansi(output).splitlines():
        m = re.match(r"^\s*URL\s*:\s*(.+)\s*$", ln)
        if m:
            url = m.group(1).strip()
        m = re.match(r"^\s*HTTP\s*:\s*(.+)\s*$", ln)
        if m:
            http = m.group(1).strip()
        m = re.match(r"^\s*Time\s*:\s*(.+)\s*$", ln)
        if m:
            t = m.group(1).strip()
    t = t[:-1] if t.endswith("s") else t
    return url, http, t


def build_url_dashboard(hdr: Dict[str, str], raw_output: str) -> List[Dict[str, Any]]:
    client = hdr.get("Client", "Unknown")
    host = hdr.get("Host", "Unknown")
    env = hdr.get("Env", "Unknown")
    app_name = hdr.get("App", "Unknown")

    url, http_code, time_s = parse_url_result(raw_output)

    icon = "⚪"
    try:
        code = int(http_code)
        if 200 <= code < 300:
            icon = "🟢"
        elif 300 <= code < 400:
            icon = "🟡"
        else:
            icon = "🔴"
    except Exception:
        icon = "🔴" if http_code and http_code != "ERROR" else "⚪"

    blocks: List[Dict[str, Any]] = [
        {"type": "header", "text": {"type": "plain_text", "text": "URL Health Check", "emoji": True}},
        {"type": "section", "text": {"type": "mrkdwn", "text": f"{icon} *{app_name}* on *{host}*\n*Client:* {client}\n*Environment:* {env}"}},
        {"type": "divider"},
        {"type": "section", "fields": [
            {"type": "mrkdwn", "text": f"*HTTP:*\n{icon} *{http_code or '—'}*"},
            {"type": "mrkdwn", "text": f"*Time:*\n{(time_s + 's') if time_s else '—'}"},
        ]},
    ]
    if url:
        blocks.append({"type": "section", "text": {"type": "mrkdwn", "text": f"*URL:*\n{url}"}})
    return blocks


def _looks_failed(payload: Dict[str, Any]) -> bool:
    """
    Determine success/failure based on run_ctl output conventions.
    - run_ctl returns 'Exit N\n...' on non-zero exit.
    - Some validations return text starting with 'ERROR:'.
    """
    text = (payload.get("text") or "").strip()
    if text.startswith("Exit "):
        return True
    if "ERROR:" in text:
        return True
    return False


def _decorate_payload(payload: Dict[str, Any], ok: bool, elapsed_s: float, user_text: str) -> Dict[str, Any]:
    status = "✅ Success" if ok else "❌ Failed"
    prefix = f"{status}  ·  Completed in {elapsed_s:.2f}s"
    cmd_line = f"*Command:* `{user_text or '(no args)'}`"

    # If blocks exist (dashboards), add a small section on top
    if isinstance(payload.get("blocks"), list) and payload["blocks"]:
        new_blocks: List[Dict[str, Any]] = [
            {"type": "section", "text": {"type": "mrkdwn", "text": f"{prefix}\n{cmd_line}"}},
            {"type": "divider"},
        ] + payload["blocks"]
        payload["blocks"] = new_blocks
        # Ensure text exists for fallback
        payload["text"] = payload.get("text") or (status)
        return payload

    # Raw text fallback
    existing = payload.get("text") or ""
    payload["text"] = f"{prefix}\n{cmd_line}\n{existing}" if existing else f"{prefix}\n{cmd_line}"
    return payload


def run_ctl(user_text: str) -> Dict[str, Any]:
    parts = shlex.split(user_text)
    if not parts:
        return {"text": build_usage_text()}

    core, ctl_flags, bot_flags = split_flags(parts)
    if not core:
        return {"text": build_usage_text()}

    cmd = core[0]
    if cmd not in ALLOWED_CMDS:
        return {"text": f"Subcommand not allowed: `{cmd}`\n\n{build_usage_text()}"}

    if cmd in ("info", "status"):
        if len(core) < 3:
            return {"text": f"ERROR: `{cmd}` requires <CLIENT> <HOST|ENV> [APP]\n\n{build_usage_text()}"}
    else:
        if len(core) < 4:
            return {"text": f"ERROR: `{cmd}` requires <CLIENT> <HOST|ENV> <APP>\n\n{build_usage_text()}"}

    exec_mode = ("--exec" in ctl_flags)
    force_raw = ("--raw" in bot_flags)

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
        return {"text": f"Error running {APP_BRAND}: {e}"}

    combined = ((p.stdout or "") + ("\n" + p.stderr if p.stderr else "")).strip()
    combined_clean = strip_ansi(combined)

    summary_single = parse_status_details_systemctl(combined_clean) if cmd == "status" else None

    if p.returncode != 0:
        return {"text": "Exit {}\n{}".format(p.returncode, to_raw_response(combined_clean, summary_single)["text"])}

    if cmd == "info":
        return {"text": "```{}```".format(combined_clean[:3900])}

    if cmd == "url":
        if force_raw or (not exec_mode):
            return {"text": "```{}```".format(combined_clean[:3900])}
        hdr = parse_header_details(combined_clean)
        return {"text": "URL", "blocks": build_url_dashboard(hdr, combined_clean)}

    if cmd == "status":
        if force_raw or (not exec_mode):
            return to_raw_response(combined_clean, summary_single)

        if "Component:" in combined_clean or "Main-State:" in combined_clean:
            host_chunks = split_host_runs(combined_clean)
            parsed_sections: List[Dict[str, Any]] = []
            for ch in host_chunks:
                sec = parse_component_status_section(ch)
                if sec:
                    parsed_sections.append(sec)

            if parsed_sections:
                return {"text": "Status", "blocks": build_component_status_blocks(parsed_sections)}

        if "App    : <ALL>" in combined_clean and "APP:" in combined_clean:
            sections = parse_status_multi_allapps(combined_clean)
            if sections:
                return {"text": "Status", "blocks": build_status_multi_blocks(sections)}
            return to_raw_response(combined_clean, summary_single)

        if summary_single and summary_single.get("State") and summary_single.get("State") != "UNKNOWN":
            return {"text": "Status", "blocks": build_blocks_like_image(summary_single or {})}

        return {"text": "```{}```".format(combined_clean[:3900])}

    return to_raw_response(combined_clean, summary_single)


def register_commands():
    @app.command(SLASH_CMD)
    def handle_slash(ack, respond, command):
        ack()

        user_text = (command.get("text") or "").strip()

        # Immediate feedback (ephemeral)
        respond(
            text=f"🔄 *{APP_BRAND}* is executing:\n`{user_text or '(no args)'}`",
            response_type="ephemeral",
        )

        t0 = time.time()
        payload = run_ctl(user_text)
        elapsed = time.time() - t0

        ok = not _looks_failed(payload)
        payload = _decorate_payload(payload, ok=ok, elapsed_s=elapsed, user_text=user_text)

        respond(**payload)

register_commands()

if __name__ == "__main__":
    log.info("Starting %s Slack bot...", APP_BRAND)
    log.info("SLASH_CMD=%s", SLASH_CMD)
    log.info("CTL_BIN=%s", CTL_BIN)
    log.info("CTL_HOME=%s", CTL_HOME)
    log.info("TIMEOUT=%s", TIMEOUT)
    SocketModeHandler(app, APP_TOKEN).start()
