#!/usr/bin/env python3

import os
import time
import socket
import platform
import shutil
from datetime import datetime

LOG_FILE = "/var/log/system_monitor.log"
INTERVAL_SECONDS = 60


def get_cpu_load():
    load1, load5, load15 = os.getloadavg()
    cpu_count = os.cpu_count() or 1
    return {
        "load_1m": round(load1, 2),
        "load_5m": round(load5, 2),
        "load_15m": round(load15, 2),
        "cpu_count": cpu_count,
        "load_percent": round((load1 / cpu_count) * 100, 2)
    }


def get_memory_usage():
    with open("/proc/meminfo", "r") as f:
        meminfo = f.readlines()

    mem_data = {}
    for line in meminfo:
        key, value = line.split(":")
        mem_data[key] = int(value.strip().split()[0])

    total = mem_data["MemTotal"]
    available = mem_data["MemAvailable"]
    used = total - available

    return {
        "total_mb": round(total / 1024, 2),
        "used_mb": round(used / 1024, 2),
        "available_mb": round(available / 1024, 2),
        "used_percent": round((used / total) * 100, 2)
    }


def get_disk_usage(path="/"):
    usage = shutil.disk_usage(path)
    return {
        "total_gb": round(usage.total / (1024 ** 3), 2),
        "used_gb": round(usage.used / (1024 ** 3), 2),
        "free_gb": round(usage.free / (1024 ** 3), 2),
        "used_percent": round((usage.used / usage.total) * 100, 2)
    }


def write_log():
    hostname = socket.gethostname()
    os_name = platform.platform()

    cpu = get_cpu_load()
    memory = get_memory_usage()
    disk = get_disk_usage("/")

    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    log_entry = (
        f"[{timestamp}] "
        f"host={hostname} "
        f"os='{os_name}' "
        f"cpu_load_1m={cpu['load_1m']} "
        f"cpu_load_percent={cpu['load_percent']}% "
        f"memory_used={memory['used_percent']}% "
        f"memory_available_mb={memory['available_mb']} "
        f"disk_used={disk['used_percent']}% "
        f"disk_free_gb={disk['free_gb']}"
    )

    with open(LOG_FILE, "a") as log:
        log.write(log_entry + "\n")


def main():
    while True:
        try:
            write_log()
        except Exception as e:
            with open(LOG_FILE, "a") as log:
                log.write(f"[ERROR] {datetime.now()} {e}\n")

        time.sleep(INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
