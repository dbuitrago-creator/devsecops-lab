#!/usr/bin/env bash

LOG_FILE="/var/log/system_monitor.log"
INTERVAL_SECONDS=60

get_os_info() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        echo "$PRETTY_NAME"
    else
        uname -a
    fi
}

while true; do
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    HOSTNAME=$(hostname)
    OS_INFO=$(get_os_info)

    CPU_LOAD=$(awk '{print $1}' /proc/loadavg)
    CPU_COUNT=$(nproc)
    CPU_PERCENT=$(awk -v load="$CPU_LOAD" -v cores="$CPU_COUNT" \
        'BEGIN { printf "%.2f", (load / cores) * 100 }')

    MEM_TOTAL=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    MEM_AVAILABLE=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    MEM_USED=$((MEM_TOTAL - MEM_AVAILABLE))
    MEM_PERCENT=$(awk -v used="$MEM_USED" -v total="$MEM_TOTAL" \
        'BEGIN { printf "%.2f", (used / total) * 100 }')

    DISK_PERCENT=$(df -h / | awk 'NR==2 {print $5}')
    DISK_FREE=$(df -h / | awk 'NR==2 {print $4}')

    echo "[$TIMESTAMP] host=$HOSTNAME os=\"$OS_INFO\" cpu_load_1m=$CPU_LOAD cpu_load_percent=${CPU_PERCENT}% memory_used=${MEM_PERCENT}% disk_used=$DISK_PERCENT disk_free=$DISK_FREE" >> "$LOG_FILE"

    sleep "$INTERVAL_SECONDS"
done
