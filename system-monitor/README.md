# System Monitor (Python + Bash)

## Overview
This project is a lightweight, cross-platform system monitoring solution designed for Linux environments such as Ubuntu and Rocky Linux. It continuously collects key system health metrics and runs as a background service using `systemd`.

The project includes **two implementations**:
- Python (primary – service deployment)
- Bash (secondary – portability and scripting demonstration)

This dual implementation highlights both **software engineering capability** and **Linux system-level proficiency**, aligning with real-world DevOps and DevSecOps practices.

---

## Key Features
- Continuous system monitoring via `systemd`
- Cross-distro support (Ubuntu, Rocky Linux)
- Dual implementation (Python + Bash)
- Minimal dependencies (native Linux tools)
- Structured logging for observability and analysis

---

## Metrics Collected
- CPU Load (1-minute average)
- CPU utilization relative to core count
- Memory usage (total, used, available)
- Disk usage (percentage and available space)
- Hostname and OS information
- Timestamped logs for historical tracking

---

## Architecture
Linux Host (Ubuntu / Rocky)
│
▼
systemd Service
│
▼
Monitoring Script
(Python or Bash)
│
▼
System Resources
(/proc, df, OS info)
│
▼
Log Output
/var/log/system_monitor.log
│
▼
Future Integrations
(Log Analyzer / SIEM / Alerting)


---

## How It Works
1. A `systemd` service runs the monitoring script in the background  
2. The script collects system metrics at fixed intervals  
3. Metrics are formatted into structured log entries  
4. Logs are written to `/var/log/system_monitor.log`  
5. The service automatically restarts on failure  

---

## Project Structure
