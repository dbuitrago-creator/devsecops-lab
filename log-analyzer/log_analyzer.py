#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import socket
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any


FAILED_PATTERNS = re.compile(r"Failed password|Invalid user")
ACCEPTED_PATTERNS = re.compile(r"Accepted (publickey|password)")
SUDO_FAILURE_PATTERNS = re.compile(
    r"sudo:.*(authentication failure|incorrect password|not in sudoers|not allowed|command not allowed)",
    re.IGNORECASE,
)
PAM_AUTH_FAILURE_PATTERNS = re.compile(
    r"pam_unix\((sshd|sudo):auth\): authentication failure",
    re.IGNORECASE,
)


@dataclass
class SSHJournalSource:
    mode: str  # "unit" or "comm"
    key: str   # "ssh" / "sshd"


def run_command(cmd: list[str], check: bool = False) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        cmd,
        text=True,
        capture_output=True,
        check=check,
    )


def get_os_info() -> tuple[str, str]:
    os_id = "unknown"
    pretty_name = "Unknown"

    os_release = Path("/etc/os-release")
    if os_release.exists():
        data: dict[str, str] = {}
        for line in os_release.read_text().splitlines():
            if "=" not in line or line.strip().startswith("#"):
                continue
            key, value = line.split("=", 1)
            data[key] = value.strip().strip('"')
        os_id = data.get("ID", "unknown")
        pretty_name = data.get("PRETTY_NAME", "Unknown")
    return os_id, pretty_name


def default_ssh_unit_for_os(os_id: str) -> str:
    if os_id == "ubuntu":
        return "ssh"
    if os_id in {"rocky", "rhel", "centos", "fedora"}:
        return "sshd"
    return "sshd"


def unit_exists(unit_name: str) -> bool:
    result = run_command(["systemctl", "list-unit-files"])
    if result.returncode != 0:
        return False
    return f"{unit_name}.service" in result.stdout


def comm_has_logs(comm_name: str) -> bool:
    result = run_command(["sudo", "journalctl", f"_COMM={comm_name}", "-n", "1"])
    return result.returncode == 0 and bool(result.stdout.strip())


def select_ssh_journal_source(preferred_unit: str) -> SSHJournalSource:
    if unit_exists(preferred_unit):
        return SSHJournalSource(mode="unit", key=preferred_unit)
    for candidate in ("sshd", "ssh"):
        if unit_exists(candidate):
            return SSHJournalSource(mode="unit", key=candidate)
    if comm_has_logs("sshd"):
        return SSHJournalSource(mode="comm", key="sshd")
    raise RuntimeError("Could not locate SSH logs via systemd unit or _COMM=sshd.")


def range_to_since(range_label: str) -> str:
    mapping = {
        "24h": "24 hours ago",
        "7d": "7 days ago",
    }
    try:
        return mapping[range_label]
    except KeyError as exc:
        raise ValueError("range must be one of: 24h, 7d") from exc


def build_journalctl_cmd(source: SSHJournalSource, since_str: str, reverse: bool = False) -> list[str]:
    cmd = ["sudo", "journalctl"]
    if reverse:
        cmd.append("-r")
    cmd.extend(["--since", since_str])

    if source.mode == "unit":
        cmd.extend(["-u", source.key])
    else:
        cmd.append(f"_COMM={source.key}")
    return cmd


def get_ssh_logs(source: SSHJournalSource, since_str: str, reverse: bool = False) -> list[str]:
    cmd = build_journalctl_cmd(source, since_str, reverse=reverse)
    result = run_command(cmd)
    if result.returncode != 0:
        raise RuntimeError(f"journalctl failed: {' '.join(shlex.quote(x) for x in cmd)}\n{result.stderr}")
    return [line for line in result.stdout.splitlines() if line.strip()]


def get_global_logs(since_str: str, reverse: bool = False) -> list[str]:
    cmd = ["sudo", "journalctl"]
    if reverse:
        cmd.append("-r")
    cmd.extend(["--since", since_str])
    result = run_command(cmd)
    if result.returncode != 0:
        raise RuntimeError(f"journalctl failed: {result.stderr}")
    return [line for line in result.stdout.splitlines() if line.strip()]


def extract_token_after(line: str, token: str) -> str | None:
    parts = line.split()
    for i, part in enumerate(parts):
        if part == token and i + 1 < len(parts):
            return parts[i + 1]
    return None


def parse_top_failed_ips(lines: list[str], top_n: int) -> list[dict[str, Any]]:
    failed_lines = [line for line in lines if FAILED_PATTERNS.search(line)]
    ips: list[str] = []
    for line in failed_lines:
        ip = extract_token_after(line, "from")
        if ip:
            ips.append(ip)

    counts = Counter(ips).most_common(top_n)
    return [{"ip": ip, "count": count} for ip, count in counts]


def parse_accepted_sessions(lines: list[str], top_n: int) -> list[dict[str, Any]]:
    accepted_lines = [line for line in lines if ACCEPTED_PATTERNS.search(line)]
    sessions: list[dict[str, Any]] = []

    for line in accepted_lines[:top_n]:
        parts = line.split()
        if len(parts) < 3:
            continue

        timestamp = " ".join(parts[:3])
        method = extract_token_after(line, "Accepted")
        user = extract_token_after(line, "for")
        ip = extract_token_after(line, "from")

        if method and user and ip:
            sessions.append(
                {
                    "timestamp": timestamp,
                    "user": user,
                    "ip": ip,
                    "method": method,
                }
            )
    return sessions


def parse_sudo_failures(lines: list[str], top_n: int) -> list[dict[str, Any]]:
    matches = [line for line in lines if SUDO_FAILURE_PATTERNS.search(line)]
    results: list[dict[str, Any]] = []

    for line in matches[:top_n]:
        parts = line.split()
        timestamp = " ".join(parts[:3]) if len(parts) >= 3 else ""
        results.append(
            {
                "timestamp": timestamp,
                "raw": line,
            }
        )
    return results


def parse_pam_auth_failures(lines: list[str], top_n: int) -> list[dict[str, Any]]:
    matches = [line for line in lines if PAM_AUTH_FAILURE_PATTERNS.search(line)]
    results: list[dict[str, Any]] = []

    for line in matches[:top_n]:
        parts = line.split()
        timestamp = " ".join(parts[:3]) if len(parts) >= 3 else ""
        service = next((p for p in parts if p.startswith("pam_unix(")), "")
        user_field = next((p for p in parts if p.startswith("user=")), "")
        rhost_field = next((p for p in parts if p.startswith("rhost=")), "")

        results.append(
            {
                "timestamp": timestamp,
                "service": service,
                "user": user_field.replace("user=", "", 1) if user_field else "",
                "rhost": rhost_field.replace("rhost=", "", 1) if rhost_field else "",
                "raw": line,
            }
        )
    return results


def build_report(range_label: str, top_n: int) -> dict[str, Any]:
    os_id, pretty_os = get_os_info()
    preferred_unit = default_ssh_unit_for_os(os_id)
    ssh_source = select_ssh_journal_source(preferred_unit)
    since_str = range_to_since(range_label)

    ssh_lines = get_ssh_logs(ssh_source, since_str, reverse=True)
    global_lines = get_global_logs(since_str, reverse=True)

    report = {
        "host": socket.gethostname(),
        "os": pretty_os,
        "range": range_label,
        "since": since_str,
        "ssh_log_source": {
            "mode": ssh_source.mode,
            "key": ssh_source.key,
        },
        "top_failed_ips": parse_top_failed_ips(ssh_lines, top_n),
        "accepted_sessions": parse_accepted_sessions(ssh_lines, top_n),
        "sudo_failures": parse_sudo_failures(global_lines, top_n),
        "pam_auth_failures": parse_pam_auth_failures(global_lines, top_n),
    }
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="SSH / auth log analyzer with JSON output.")
    parser.add_argument("--range", choices=["24h", "7d"], default="24h", help="Time window")
    parser.add_argument("--top", type=int, default=10, help="Number of results to return")
    parser.add_argument("--json", action="store_true", help="Print JSON output")
    parser.add_argument("--out", type=str, help="Write JSON output to a file")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    try:
        report = build_report(range_label=args.range, top_n=args.top)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    output = json.dumps(report, indent=2)

    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(output + "\n", encoding="utf-8")

    if args.json or not args.out:
        print(output)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
