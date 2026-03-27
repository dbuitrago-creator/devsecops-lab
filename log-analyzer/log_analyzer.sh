#!/bin/bash
set -euo pipefail

# -----------------------------
# Defaults
# -----------------------------
TOP_N=10
RANGE="24h"          # 24h or 7d
BOTH=false
OUTDIR="reports"     # GitHub-friendly: resolves relative to script dir below
BASELINE_FILE="baseline/known_ips.txt"
UPDATE_BASELINE=false

# These get set by the OS profile loaders (or --unit override)
SSH_UNIT=""
OS_NAME=""

# SSH journald backend selector
#   mode=unit -> journalctl -u <unit>
#   mode=comm -> journalctl _COMM=<name>
SSH_JOURNAL_MODE=""   # "unit" or "comm"
SSH_JOURNAL_KEY=""    # "sshd" or "ssh" (or "sshd" for comm fallback)

# Resolve paths relative to this script (works "run from anywhere")
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${OUTDIR/#\~/$HOME}"
if [[ "$OUTDIR" != /* ]]; then
  OUTDIR="$SCRIPT_DIR/$OUTDIR"
fi
if [[ "$BASELINE_FILE" != /* ]]; then
  BASELINE_FILE="$SCRIPT_DIR/$BASELINE_FILE"
fi

usage() {
  cat <<'USAGE'
Usage:
  ./log_analyzer.sh [--top N] [--range 24h|7d] [--both] [--outdir PATH] [--unit ssh|sshd] [--update-baseline]

Options:
  --top N              Number of results (default: 10)
  --range 24h|7d       Time window (default: 24h)
  --both               Generate BOTH 24h and 7d reports (ignores --range)
  --outdir PATH        Where to write reports (default: reports/ under script dir)
  --unit ssh|sshd      Override SSH systemd unit name (best-effort; may fallback to _COMM)
  --update-baseline    Add NEW failed-login IPs to baseline file (manual approval)
  -h, --help           Show help

Examples:
  ./log_analyzer.sh
  ./log_analyzer.sh --range 7d --top 20
  ./log_analyzer.sh --both
  ./log_analyzer.sh --unit ssh --range 24h
  ./log_analyzer.sh --range 24h --update-baseline
USAGE
}

# -----------------------------
# Arg parsing (flags)
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --top)
      TOP_N="${2:?Missing value for --top}"
      shift 2
      ;;
    --range)
      RANGE="${2:?Missing value for --range}"
      shift 2
      ;;
    --both)
      BOTH=true
      shift
      ;;
    --outdir)
      OUTDIR="${2:?Missing value for --outdir}"
      OUTDIR="${OUTDIR/#\~/$HOME}"
      if [[ "$OUTDIR" != /* ]]; then
        OUTDIR="$SCRIPT_DIR/$OUTDIR"
      fi
      shift 2
      ;;
    --unit)
      SSH_UNIT="${2:?Missing value for --unit}"
      shift 2
      ;;
    --update-baseline)
      UPDATE_BASELINE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

range_to_since() {
  case "$1" in
    24h) echo "24 hours ago" ;;
    7d)  echo "7 days ago" ;;
    *)
      echo "Invalid range: $1 (use 24h or 7d)" >&2
      exit 1
      ;;
  esac
}

# -----------------------------
# OS Profiles (modular approach)
# -----------------------------
load_ubuntu_profile() {
  OS_NAME="Ubuntu"
  SSH_UNIT="${SSH_UNIT:-ssh}"
}

load_rocky_profile() {
  OS_NAME="Rocky Linux"
  SSH_UNIT="${SSH_UNIT:-sshd}"
}

detect_os_and_load_profile() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
      ubuntu) load_ubuntu_profile; return ;;
      rocky|rhel|centos|fedora) load_rocky_profile; return ;;
    esac
  fi

  # Fallback
  local os_info
  os_info="$(hostnamectl 2>/dev/null | grep -i "Operating System" || true)"
  if [[ "$os_info" == *"Ubuntu"* ]]; then
    load_ubuntu_profile
  elif [[ "$os_info" == *"Rocky"* ]]; then
    load_rocky_profile
  else
    OS_NAME="Unknown"
    SSH_UNIT="${SSH_UNIT:-sshd}"
  fi
}

# -----------------------------
# SSH journal source selection (unit -> comm fallback)
# -----------------------------
select_ssh_journal_source() {
  # 1) If the requested/default unit exists, use unit mode
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "${SSH_UNIT}.service"; then
    SSH_JOURNAL_MODE="unit"
    SSH_JOURNAL_KEY="$SSH_UNIT"
    return
  fi

  # 2) Try common unit names
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "sshd.service"; then
    SSH_UNIT="sshd"
    SSH_JOURNAL_MODE="unit"
    SSH_JOURNAL_KEY="sshd"
    return
  fi
  if systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "ssh.service"; then
    SSH_UNIT="ssh"
    SSH_JOURNAL_MODE="unit"
    SSH_JOURNAL_KEY="ssh"
    return
  fi

  # 3) Fallback: journald process name filter (_COMM=sshd)
  if sudo journalctl _COMM=sshd -n 1 >/dev/null 2>&1; then
    SSH_JOURNAL_MODE="comm"
    SSH_JOURNAL_KEY="sshd"
    return
  fi

  echo "ERROR: Could not find SSH logs via systemd unit or _COMM=sshd." >&2
  echo "Tip: verify sshd is running and journald is capturing logs." >&2
  exit 1
}

# IMPORTANT: journalctl argument order matters.
# We accept extra journalctl options (e.g., -r) and place them BEFORE matches.
ssh_journalctl() {
  local since_str="$1"; shift
  local opts=("$@")

  if [[ "$SSH_JOURNAL_MODE" == "unit" ]]; then
    sudo journalctl "${opts[@]}" -u "$SSH_JOURNAL_KEY" --since "$since_str"
  else
    sudo journalctl "${opts[@]}" --since "$since_str" _COMM="$SSH_JOURNAL_KEY"
  fi
}

# -----------------------------
# Analyzers
# -----------------------------
print_failed_attempts() {
  local since_str="$1"
  echo -e "\n[!] TOP ${TOP_N} FAILED SSH ATTEMPTS BY IP (since ${since_str}):"

  ssh_journalctl "$since_str" \
    | grep -E "Failed password|Invalid user" \
    | awk '{
        for (i=1; i<=NF; i++) {
          if ($i=="from") { print $(i+1); break }
        }
      }' \
    | sort | uniq -c | sort -nr | head -n "$TOP_N"
}

print_accepted_sessions() {
  local since_str="$1"
  echo -e "\n[✓] MOST RECENT ${TOP_N} ACCEPTED SESSIONS (since ${since_str}):"

  # -r makes journalctl return newest first; we then take head -n TOP_N.
  ssh_journalctl "$since_str" -r \
    | grep -E "Accepted (publickey|password)" \
    | head -n "$TOP_N" \
    | awk '{
        ts = $1 " " $2 " " $3;
        method=""; user=""; ip="";
        for (i=1; i<=NF; i++) {
          if ($i=="Accepted") method=$(i+1);
          if ($i=="for") user=$(i+1);
          if ($i=="from") ip=$(i+1);
        }
        if (method!="" && user!="" && ip!="")
          print ts "  user=" user "  ip=" ip "  method=" method;
      }'
}

print_sudo_failures() {
  local since_str="$1"
  echo -e "\n[!] SUDO FAILURES (since ${since_str}):"

  local matches
  matches="$(sudo journalctl --since "$since_str" \
    | grep -Ei "sudo:.*(authentication failure|incorrect password|not in sudoers|not allowed|command not allowed)" \
    | head -n "$TOP_N" || true)"

  if [[ -z "$matches" ]]; then
    echo "None found."
  else
    echo "$matches"
  fi
}

print_pam_auth_failures() {
  local since_str="$1"
  echo -e "\n[!] PAM/AUTH FAILURES (since ${since_str}):"

  local matches
  matches="$(sudo journalctl --since "$since_str" \
    | grep -Ei "pam_unix\((sshd|sudo):auth\): authentication failure" \
    | head -n "$TOP_N" || true)"

  if [[ -z "$matches" ]]; then
    echo "None found."
    return
  fi

  echo "$matches" | awk '{
      ts=$1" "$2" "$3;
      service=""; user=""; rhost="";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^pam_unix\(/) service=$i;
        if ($i ~ /^user=/) user=$i;
        if ($i ~ /^rhost=/) rhost=$i;
      }
      print ts "  " service "  " user "  " rhost;
    }'
}

get_top_failed_ips() {
  local since_str="$1"
  ssh_journalctl "$since_str" \
    | grep -E "Failed password|Invalid user" \
    | awk '{for(i=1;i<=NF;i++) if($i=="from"){print $(i+1); break}}' \
    | sort | uniq -c | sort -nr | head -n "$TOP_N" \
    | awk '{print $2}'
}

print_new_failed_ips_vs_baseline() {
  local since_str="$1"
  echo -e "\n[*] BASELINE CHECK (new failed-login IPs vs ${BASELINE_FILE}):"

  mkdir -p "$(dirname "$BASELINE_FILE")"
  touch "$BASELINE_FILE"

  local ips
  ips="$(get_top_failed_ips "$since_str" || true)"

  if [[ -z "$ips" ]]; then
    echo "No failed-login IPs to compare."
    return
  fi

  while read -r ip; do
    [[ -z "$ip" ]] && continue
    if grep -qx "$ip" "$BASELINE_FILE"; then
      echo "known  $ip"
    else
      echo "NEW    $ip"
      if [[ "$UPDATE_BASELINE" == true ]]; then
        echo "$ip" >> "$BASELINE_FILE"
      fi
    fi
  done <<< "$ips"

  if [[ "$UPDATE_BASELINE" == true ]]; then
    sort -u "$BASELINE_FILE" -o "$BASELINE_FILE"
    echo "Baseline updated."
  else
    echo "Tip: run with --update-baseline to add NEW IPs to baseline."
  fi
}

# -----------------------------
# Report Generator
# -----------------------------
generate_report() {
  local range_label="$1"  # 24h or 7d
  local since_str
  since_str="$(range_to_since "$range_label")"

  mkdir -p "$OUTDIR"

  local host pretty_os ts report_file
  host="$(hostname -f 2>/dev/null || hostname)"
  pretty_os="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$OS_NAME}")"
  ts="$(date +%Y%m%d_%H%M%S)"
  report_file="${OUTDIR}/ssh_report_${range_label}_${host}_${ts}.txt"

  {
    echo "=========================================="
    echo "SSH SECURITY REPORT - $(date)"
    echo "Host: $host"
    echo "OS: $pretty_os"
    echo "SSH Profile Unit Default: ${SSH_UNIT}.service"
    echo "SSH Log Source: ${SSH_JOURNAL_MODE}=${SSH_JOURNAL_KEY}"
    echo "Range: ${range_label} (since: ${since_str})"
    echo "Outdir: $OUTDIR"
    echo "=========================================="

    print_failed_attempts "$since_str"
    print_new_failed_ips_vs_baseline "$since_str"
    print_accepted_sessions "$since_str"
    print_sudo_failures "$since_str"
    print_pam_auth_failures "$since_str"
  } > "$report_file"

  echo "Report generated: $report_file"
}

# -----------------------------
# Main
# -----------------------------
detect_os_and_load_profile
select_ssh_journal_source

if [[ "$BOTH" == true ]]; then
  generate_report "24h"
  generate_report "7d"
else
  generate_report "$RANGE"
fi
