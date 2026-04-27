# DevSecOps Engineering Lab — High-Level Overview  
*A hands-on portfolio demonstrating Linux, automation, scripting, DevOps tooling, and infrastructure skills.*

## 📌 Purpose of This Lab

This repository is a structured DevOps engineering lab designed to demonstrate real-world skills across:

- Linux system administration (Ubuntu & Rocky Linux)
- Bash + Python automation
- Infrastructure-as-Code
- Configuration management
- Containerization (Docker)
- Git branching strategy & workflow
- Security hardening & SSH automation
- CI/CD readiness

The goal is to show **practical, job-ready DevOps and QA automation capabilities**, not tutorial code.

Everything in this repo mirrors tasks performed by DevOps, SRE, QA Automation, and Platform Engineers.

---

## 📁 Project Overview

Below is the list of projects included and planned for this repository.

### ✅ 1. **Log Analyzer (Bash + Python)**
A cross-platform log parsing tool for:

- SSH login failures
- sudo usage
- authentication events
- suspicious IPs
- service errors

Skills demonstrated:
regex, awk, sed, Python parsing, security visibility, system troubleshooting.

---

### ✅ 2. **Backup Automation Tool**
Automates:

- Compressed backups of directories
- Timestamped versioning
- Deletion rotation policies
- Optional checksums
- Optional SCP/remote backup

Skills demonstrated:
shell scripting, tar, Python automation, cron, systemd timers.

---

### ✅ 3. **System Monitor (CLI + Service)**
A tool that reports:

- CPU usage 
- Memory usage 
- Disk usage 
- Load averages 
- Optional logging or alerts 

Includes a **systemd service** configuration to run automatically.

Skills demonstrated:
psutil, Linux procfs, systemd, monitoring design.

---

### 📦 4. **Docker Projects**
Located in docker-projects/

#### • Python App Container  
Simple Python microservice demonstrating:

- Dockerfile best practices 
- Multi-stage builds (future enhancement) 
- Container logging 

#### • Nginx Test Container  
Used to practice:

- Basic reverse proxying 
- Docker networking 
- Container environments 

Skills demonstrated:
Docker, images, layers, CMD/ENTRYPOINT, container networking.

---

### ⚙️ 5. **Ansible Playbooks**
The ansible-playbooks/ directory includes:

- Inventory for Ubuntu + Rocky Linux servers
- Group variables & host variables
- Roles for common, web, and db configuration
- A site.yml orchestrating multi-node setups

Skills demonstrated:
Ansible, IaC, automation workflows, YAML, idempotent deployments.

---

## 🔐 Server Environment for This Lab

This lab is built and tested on:

- **Ubuntu Server (Minimal)**
- **Rocky Linux 9 (Minimal)**

Configured with:

- SSH key-only authentication 
- Disabled root login 
- Hardened SSH policies 
- Git SSH integration 
- Docker installed on both OS types 

This simulates real on-prem or cloud Linux infrastructure.

---

## 🌱 Future Enhancements (Roadmap)

Planned additions:

### 📌 Upcoming Projects
- Kubernetes (k3s) cluster
- Docker Compose multi-service app
- CI/CD pipeline using GitHub Actions
- ELK / Loki log stack
- Prometheus + Grafana monitoring
- Terraform cloud provisioning modules
- Advanced Ansible roles (firewall, SELinux, HAProxy)
- Security scanning tools (OpenSCAP, Lynis)

---

## 🧪 Git Workflow Used in This Repo

This project uses a professional branch model:

- main → stable, portfolio-ready 
- dev → integration/testing 
- feature/...` → isolated development per task 

Every feature is merged into dev, then into main, mirroring real DevOps workflows.

---

## 🛠️ Tools & Technologies

| Category | Tools |
|---------|-------|
| OS | Ubuntu Server, Rocky Linux |
| Languages | Bash, Python |
| DevOps | Docker, Ansible |
| Version Control | Git + GitHub (SSH only) |
| Automation | systemd, cron, shell scripts |
| Security | SSH hardening, key auth |
| Networking | Linux CLI tools, networking basics |

---

## 📬 About This Lab

This repository is part of an ongoing multi-week project to rebuild and refine **core DevOps, Linux, QA, and automation skills** through:

- Working systems 
- Real scripts 
- Real servers 
- Intentional Git workflows 
- Professional documentation 

This repo is designed to reflect **actual engineering ability**, not toy examples.

---

## 💼 Author

**Diego Buitrago** 
DevOps / QA Automation / Security Engineering Path 
GitHub: **dbuitrago-creator**

---


