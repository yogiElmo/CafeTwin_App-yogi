#!/bin/bash
# ============================================================
# CaféTwin — Gateway Firewall Hardening Script
# Author : Rudra Pratap (SCI7137)
# Sprint : Week 7 — Network Security & Backend Protection
# ============================================================

set -euo pipefail

echo "[*] Flushing existing iptables rules..."
iptables -F
iptables -X
iptables -t nat -F

# Default policy: drop everything, then whitelist
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# SSH access (admin only — restrict to management subnet)
iptables -A INPUT -p tcp --dport 22 -s 192.168.1.0/24 -j ACCEPT

# PostgreSQL — internal only (backend container → db container)
iptables -A INPUT -p tcp --dport 5432 -s 172.16.0.0/12 -j ACCEPT

# CaféTwin API — allow from café LAN and reverse proxy
iptables -A INPUT -p tcp --dport 3000 -s 192.168.10.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 3000 -s 172.16.0.0/12 -j ACCEPT

# HTTPS (reverse proxy / Nginx frontend)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT

# Rate limit API to prevent brute-force / DoS
iptables -A INPUT -p tcp --dport 3000 -m connlimit --connlimit-above 50 -j REJECT
iptables -A INPUT -p tcp --dport 3000 -m hashlimit \
  --hashlimit-name api_limit \
  --hashlimit-above 30/min \
  --hashlimit-mode srcip \
  --hashlimit-burst 10 -j DROP

# Block common attack vectors
iptables -A INPUT -p tcp --dport 23 -j DROP    # Telnet
iptables -A INPUT -p tcp --dport 3389 -j DROP  # RDP
iptables -A INPUT -p udp --dport 161 -j DROP   # SNMP

# Log dropped packets for audit
iptables -A INPUT -j LOG --log-prefix "[CAFETWIN-DROP] " --log-level 4
iptables -A INPUT -j DROP

echo "[+] Firewall rules applied. CaféTwin backend protected."
iptables -L -n --line-numbers
