#!/bin/bash
set -euo pipefail


TOP_N=10
RANGE="24h"
BOTH=false
OUTDIR="reports"
BASELINE_FILE="baseline/known_ips.txt"
UPDATE_BASELINE=false

SSH_UNIT=""
OS_NAME=""
SSH_JOURNAL_MODE=""
SSH_JOURNAL_KEY=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${OUTDIR/#\~/$HOME}"
[[ "$OUTDIR"        != /* ]] && OUTDIR="$SCRIPT_DIR/$OUTDIR"
[[ "$BASELINE_FILE" != /* ]] && BASELINE_FILE="$SCRIPT_DIR/$BASELINE_FILE"

# Require jq — fail fast with actionable install instructions
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed." >&2
  echo "  Rocky/RHEL:  sudo dnf install jq" >&2
  echo "  Ubuntu:      sudo apt install jq" >&2
  exit 1
fi

# -----------------------------
# Usage
# -----------------------------
usage() {
  cat <<'USAGE'
Usage:
  ./log_analyzer_json.sh [OPTIONS]

Options:
  --top N              Top N results per section (default: 10, must be a positive integer)
  --range 24h|7d       Time window (default: 24h)
  --both               Generate BOTH 24h and 7d reports (ignores --range)
  --outdir PATH        Output directory (default: reports/ next to this script)
  --unit ssh|sshd      Override SSH systemd unit name (falls back to _COMM=sshd)
  --update-baseline    Append NEW failed-login IPs to baseline file
  -h, --help           Show this help

Output: one JSON file per report written to OUTDIR.
USAGE
}

# -----------------------------
# Arg parsing
# FIX-2: --top is validated as a positive integer immediately after parsing,
#         not silently passed to `head -n` where bad values cause silent errors.
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
      [[ "$OUTDIR" != /* ]] && OUTDIR="$SCRIPT_DIR/$OUTDIR"
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
      echo "ERROR: Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

# FIX-2: Validate --top now so the error message is clear and actionable,
#         rather than a cryptic failure inside head/awk later.
if ! [[ "$TOP_N" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: --top must be a positive integer (got: '$TOP_N')" >&2
  exit 1
fi

range_to_since() {
  case "$1" in
    24h) echo "24 hours ago" ;;
    7d)  echo "7 days ago"   ;;
    *)
      echo "ERROR: Invalid range '$1' — use 24h or 7d" >&2
      exit 1
      ;;
  esac
}

# -----------------------------
# OS Profiles
# -----------------------------
load_ubuntu_profile() { OS_NAME="Ubuntu";     SSH_UNIT="${SSH_UNIT:-ssh}";  }
load_rocky_profile()  { OS_NAME="Rocky Linux"; SSH_UNIT="${SSH_UNIT:-sshd}"; }

detect_os_and_load_profile() {
  if [[ -r /etc/os-release ]]; then
    # Source into a subshell so os-release variables don't pollute our env.
    local os_id
    os_id="$(. /etc/os-release && echo "${ID:-}")"
    case "$os_id" in
      ubuntu)                   load_ubuntu_profile; return ;;
      rocky|rhel|centos|fedora) load_rocky_profile;  return ;;
    esac
  fi
  local os_info
  os_info="$(hostnamectl 2>/dev/null | grep -i "Operating System" || true)"
  if   [[ "$os_info" == *Ubuntu* ]]; then load_ubuntu_profile
  elif [[ "$os_info" == *Rocky*  ]]; then load_rocky_profile
  else
    OS_NAME="Unknown"
    SSH_UNIT="${SSH_UNIT:-sshd}"
  fi
}

# FIX-8: PRETTY_NAME was previously re-sourced inside generate_report in a
#         subshell, which could shadow SSH_UNIT and OS_NAME set by the profile
#         loader.  Instead we capture it once here after profile detection.
OS_PRETTY=""
cache_pretty_name() {
  if [[ -r /etc/os-release ]]; then
    OS_PRETTY="$(. /etc/os-release && echo "${PRETTY_NAME:-$OS_NAME}")"
  else
    OS_PRETTY="$OS_NAME"
  fi
}

# -----------------------------
# SSH journal source selection
# -----------------------------
select_ssh_journal_source() {
  # Read the unit list once into a local variable to avoid three separate
  # systemctl calls. grep -qx matches exact full-line strings.
  local units
  units="$(systemctl list-unit-files 2>/dev/null | awk '{print $1}')"

  if echo "$units" | grep -qx "${SSH_UNIT}.service" 2>/dev/null; then
    SSH_JOURNAL_MODE="unit"; SSH_JOURNAL_KEY="$SSH_UNIT"; return
  fi
  if echo "$units" | grep -qx "sshd.service" 2>/dev/null; then
    SSH_UNIT="sshd"; SSH_JOURNAL_MODE="unit"; SSH_JOURNAL_KEY="sshd"; return
  fi
  if echo "$units" | grep -qx "ssh.service" 2>/dev/null; then
    SSH_UNIT="ssh";  SSH_JOURNAL_MODE="unit"; SSH_JOURNAL_KEY="ssh";  return
  fi
  if sudo journalctl _COMM=sshd -n 1 >/dev/null 2>&1; then
    SSH_JOURNAL_MODE="comm"; SSH_JOURNAL_KEY="sshd"; return
  fi

  echo "ERROR: Cannot find SSH logs via systemd unit or _COMM=sshd." >&2
  echo "       Verify sshd is running and journald is capturing its output." >&2
  exit 1
}

# FIX-9: Under set -u, expanding an empty array with "${opts[@]}" raises
#         "unbound variable" on bash < 4.4.  The idiom
#         "${opts[@]+"${opts[@]}"}" expands to nothing when the array is empty
#         and to the full array otherwise — safe on all bash 4.x versions.
ssh_journalctl() {
  local since_str="$1"; shift
  local opts=("$@")

  if [[ "$SSH_JOURNAL_MODE" == "unit" ]]; then
    sudo journalctl "${opts[@]+"${opts[@]}"}" -u "$SSH_JOURNAL_KEY" --since "$since_str"
  else
    sudo journalctl "${opts[@]+"${opts[@]}"}" --since "$since_str" _COMM="$SSH_JOURNAL_KEY"
  fi
}

# =============================================================================
# FIX-3: Shared journal cache
#
# PROBLEM: get_failed_attempts_data and get_baseline_data (via a now-removed
#          get_top_failed_ips helper) each ran the full ssh_journalctl | grep
#          pipeline independently — two complete journal scans per report.
#
# SOLUTION: cache_ssh_failed_lines runs the query exactly once per report
#           window and stores matching lines in SSH_FAILED_CACHE.
#           _top_ips_from_cache extracts ranked IPs from that cache.
#           Both get_failed_attempts_data and get_baseline_data call
#           _top_ips_from_cache — zero duplicate journal I/O.
#
#           The cache is reset at the top of each generate_report call so
#           --both produces two independent, correctly time-scoped reports.
# =============================================================================
SSH_FAILED_CACHE=""

cache_ssh_failed_lines() {
  local since_str="$1"
  SSH_FAILED_CACHE="$(
    ssh_journalctl "$since_str" \
      | grep -E "Failed password|Invalid user" || true
  )"
}

_top_ips_from_cache() {
  [[ -z "$SSH_FAILED_CACHE" ]] && return 0
  echo "$SSH_FAILED_CACHE" \
    | awk '{for(i=1;i<=NF;i++) if($i=="from"){print $(i+1); break}}' \
    | sort | uniq -c | sort -nr | head -n "$TOP_N" \
    | awk '{print $2}'
}

# =============================================================================
# JSON helpers
# =============================================================================

# array_to_json <nameref>
# Converts a bash indexed array to a JSON array of strings.
# jq -R reads each line as a raw string; jq -s slurps them into an array.
# All special characters (quotes, backslashes, control chars) are escaped by jq.
array_to_json() {
  local -n _a2j=$1
  if [[ ${#_a2j[@]} -eq 0 ]]; then echo "[]"; return; fi
  printf '%s\n' "${_a2j[@]}" | jq -R . | jq -s .
}

# tablines_to_session_json <nameref>
# Input lines: "TIMESTAMP\tUSER\tIP\tMETHOD"
# Output: JSON array of {timestamp, user, ip, method} objects
tablines_to_session_json() {
  local -n _ttsj=$1
  if [[ ${#_ttsj[@]} -eq 0 ]]; then echo "[]"; return; fi
  printf '%s\n' "${_ttsj[@]}" \
    | jq -R 'split("\t") | {timestamp:.[0], user:.[1], ip:.[2], method:.[3]}' \
    | jq -s .
}

# tablines_to_pam_json <nameref>
# Input lines: "TIMESTAMP\tSERVICE\tUSER\tRHOST"
# Output: JSON array of {timestamp, service, user, rhost} objects
tablines_to_pam_json() {
  local -n _ttpj=$1
  if [[ ${#_ttpj[@]} -eq 0 ]]; then echo "[]"; return; fi
  printf '%s\n' "${_ttpj[@]}" \
    | jq -R 'split("\t") | {timestamp:.[0], service:.[1], user:.[2], rhost:.[3]}' \
    | jq -s .
}

# =============================================================================
# Data collectors
# Each function resets its output globals first so --both runs stay isolated.
# =============================================================================

# --- Failed SSH attempts ---
# FIX-1: The original script had this structure:
#
#   print_failed_attempts() {
#     print_failed_attempts() {   # <-- nested same-name definition
#       local since_str="$1"
#       ...
#     }
#   }
#
#   Calling print_failed_attempts the first time executed only the outer body,
#   which did nothing except define the inner function under the same name.
#   The second call then ran the real logic. This was a latent bug: a single
#   call in a fresh shell produced no output at all.  Removed entirely here.
#
# FIX-3: Reads _top_ips_from_cache instead of running its own journal query.

FAILED_COUNT=0
FAILED_IPS=()

get_failed_attempts_data() {
  FAILED_COUNT=0
  FAILED_IPS=()
  mapfile -t FAILED_IPS < <(_top_ips_from_cache)
  FAILED_COUNT=${#FAILED_IPS[@]}
}

# --- Accepted sessions ---
ACCEPTED_SESSIONS=()

get_accepted_sessions_data() {
  local since_str="$1"
  ACCEPTED_SESSIONS=()

  local out
  # FIX-7: || true inside the subshell so grep exit-1 (no matches) does not
  #         kill the script under set -e.
  out="$(ssh_journalctl "$since_str" -r \
    | grep -E "Accepted (publickey|password)" || true)"

  [[ -z "$out" ]] && return

  mapfile -t ACCEPTED_SESSIONS < <(
    echo "$out" | head -n "$TOP_N" \
      | awk '{
          ts = $1 " " $2 " " $3
          method = ""; user = ""; ip = ""
          for (i = 1; i <= NF; i++) {
            if ($i == "Accepted") method = $(i+1)
            if ($i == "for")      user   = $(i+1)
            if ($i == "from")     ip     = $(i+1)
          }
          if (method != "" && user != "" && ip != "")
            printf "%s\t%s\t%s\t%s\n", ts, user, ip, method
        }'
  )
}

# --- Sudo failures ---
SUDO_FAILURES=()

get_sudo_failures_data() {
  local since_str="$1"
  SUDO_FAILURES=()

  # FIX-4: In the original, || true appeared after `| head -n "$TOP_N"` but
  #         OUTSIDE the mapfile process substitution:
  #
  #           mapfile -t SUDO_FAILURES < <(
  #             sudo journalctl ... | grep ... | head -n "$TOP_N" || true
  #           )
  #
  #         The pipeline exit code that matters is the one inside <(...).
  #         With pipefail, a grep exit-1 anywhere in the pipe propagates even
  #         through head. Moving || true to the END of the pipeline inside the
  #         process substitution ensures it is actually evaluated in that context.
  mapfile -t SUDO_FAILURES < <(
    sudo journalctl --since "$since_str" \
      | grep -Ei \
          "sudo:.*(authentication failure|incorrect password|not in sudoers|not allowed|command not allowed)" \
      | head -n "$TOP_N" \
      || true
  )
}

# --- PAM auth failures ---
PAM_FAILURES=()

get_pam_failures_data() {
  local since_str="$1"
  PAM_FAILURES=()

  # FIX-5: The original awk used regex matches ($i ~ /^user=/) to identify
  #         fields. The regex /^user=/ matches anywhere in the field value
  #         because awk's ~ operator tests against the whole string, but the ^
  #         anchor inside a field match is unreliable across awk implementations
  #         when the field contains embedded characters. Using substr() for
  #         prefix matching is explicit, portable, and immune to regex quirks.
  #
  # FIX-7: || true inside the process substitution for consistent set -e safety.
  mapfile -t PAM_FAILURES < <(
    sudo journalctl --since "$since_str" \
      | grep -Ei "pam_unix\((sshd|sudo):auth\): authentication failure" \
      | head -n "$TOP_N" \
      | awk '{
          ts = $1 " " $2 " " $3
          svc = ""; usr = ""; rh = ""
          for (i = 1; i <= NF; i++) {
            if (substr($i, 1, 9) == "pam_unix(") svc = $i
            if (substr($i, 1, 5) == "user=")      usr = $i
            if (substr($i, 1, 6) == "rhost=")     rh  = $i
          }
          printf "%s\t%s\t%s\t%s\n", ts, svc, usr, rh
        }' \
      || true
  )
}

# --- Baseline comparison ---
# FIX-6: The original had a separate get_top_failed_ips() function that ran
#         the full ssh_journalctl | grep | awk | sort | uniq pipeline — a
#         complete duplicate of what get_failed_attempts_data already did.
#         get_baseline_data called it, causing two journal scans.
#         Now both functions share _top_ips_from_cache; no helper needed.

BASELINE_KNOWN=()
BASELINE_NEW=()

get_baseline_data() {
  BASELINE_KNOWN=()
  BASELINE_NEW=()

  mkdir -p "$(dirname "$BASELINE_FILE")"
  touch "$BASELINE_FILE"

  local ip
  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    if grep -qx "$ip" "$BASELINE_FILE"; then
      BASELINE_KNOWN+=("$ip")
    else
      BASELINE_NEW+=("$ip")
      [[ "$UPDATE_BASELINE" == true ]] && echo "$ip" >> "$BASELINE_FILE"
    fi
  done < <(_top_ips_from_cache)

  if [[ "$UPDATE_BASELINE" == true ]]; then
    sort -u "$BASELINE_FILE" -o "$BASELINE_FILE"
  fi
}

# =============================================================================
# Report generator
# =============================================================================
generate_report() {
  local range_label="$1"
  local since_str
  since_str="$(range_to_since "$range_label")"

  mkdir -p "$OUTDIR"

  local host ts ts_file report_file
  host="$(hostname -f 2>/dev/null || hostname)"
  ts="$(date --iso-8601=seconds)"
  ts_file="${ts//:/}"
  report_file="${OUTDIR}/ssh_report_${range_label}_${host}_${ts_file}.json"

  echo "Running report: range=${range_label}  host=${host}"

  # FIX-3: One journal scan for the entire report.  All failed-login data
  #         collectors (_top_ips_from_cache, get_baseline_data) read from this.
  cache_ssh_failed_lines "$since_str"

  # Collect all sections
  get_failed_attempts_data                # reads cache — no since_str arg needed
  get_baseline_data                       # reads cache — no since_str arg needed
  get_accepted_sessions_data "$since_str"
  get_sudo_failures_data     "$since_str"
  get_pam_failures_data      "$since_str"

  # Convert bash arrays to JSON fragments
  local failed_ips_json accepted_json sudo_json pam_json known_json new_json
  failed_ips_json=$(array_to_json          FAILED_IPS)
  accepted_json=$(tablines_to_session_json ACCEPTED_SESSIONS)
  sudo_json=$(array_to_json                SUDO_FAILURES)
  pam_json=$(tablines_to_pam_json          PAM_FAILURES)
  known_json=$(array_to_json               BASELINE_KNOWN)
  new_json=$(array_to_json                 BASELINE_NEW)

  # Assemble and write the final JSON document.
  # --arg  : shell string  → JSON string  (jq escapes all special characters)
  # --argjson : JSON fragment → embedded as-is (not re-quoted into a string)
  jq -n \
    --arg  host              "$host" \
    --arg  os                "$OS_PRETTY" \
    --arg  generated_at      "$ts" \
    --arg  range             "$range_label" \
    --arg  since             "$since_str" \
    --arg  ssh_unit          "$SSH_UNIT" \
    --arg  ssh_journal_mode  "$SSH_JOURNAL_MODE" \
    --arg  ssh_journal_key   "$SSH_JOURNAL_KEY" \
    --arg  outdir            "$OUTDIR" \
    --arg  baseline_file     "$BASELINE_FILE" \
    --argjson failed_count   "$FAILED_COUNT" \
    --argjson failed_ips     "$failed_ips_json" \
    --argjson accepted       "$accepted_json" \
    --argjson sudo_failures  "$sudo_json" \
    --argjson pam_failures   "$pam_json" \
    --argjson baseline_known "$known_json" \
    --argjson baseline_new   "$new_json" \
    '{
      meta: {
        host:             $host,
        os:               $os,
        generated_at:     $generated_at,
        range:            $range,
        since:            $since,
        ssh_unit:         $ssh_unit,
        ssh_journal_mode: $ssh_journal_mode,
        ssh_journal_key:  $ssh_journal_key,
        outdir:           $outdir,
        baseline_file:    $baseline_file
      },
      failed_ssh_attempts: {
        count:   $failed_count,
        top_ips: $failed_ips
      },
      baseline_check: {
        known_ips: $baseline_known,
        new_ips:   $baseline_new
      },
      accepted_sessions: $accepted,
      sudo_failures:     $sudo_failures,
      pam_auth_failures: $pam_failures
    }' > "$report_file"

  echo "Report written:  $report_file"
}

# =============================================================================
# Main
# =============================================================================
detect_os_and_load_profile
cache_pretty_name           # FIX-8: capture OS_PRETTY once, outside any subshell
select_ssh_journal_source

if [[ "$BOTH" == true ]]; then
  generate_report "24h"
  generate_report "7d"
else
  generate_report "$RANGE"
fi