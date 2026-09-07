#!/bin/bash
# ============================================================
# CaféTwin — Guest Wi-Fi Network Isolation
# Author : Rudra Pratap (SCI7137)
# Sprint : Week 7 — VLAN Segmentation & Client Isolation
# ============================================================

set -euo pipefail

# Gaming stations: VLAN 10 (192.168.10.0/24)
# Guest Wi-Fi:     VLAN 20 (192.168.20.0/24)  
# Management:      VLAN 1  (192.168.1.0/24)

echo "[*] Configuring guest Wi-Fi isolation..."

# Block guest VLAN from accessing gaming VLAN
iptables -A FORWARD -s 192.168.20.0/24 -d 192.168.10.0/24 -j DROP

# Block guest VLAN from accessing management VLAN
iptables -A FORWARD -s 192.168.20.0/24 -d 192.168.1.0/24 -j DROP

# Block guest VLAN from accessing PostgreSQL directly
iptables -A FORWARD -s 192.168.20.0/24 -p tcp --dport 5432 -j DROP

# Allow guest VLAN internet access only (via NAT)
iptables -A FORWARD -s 192.168.20.0/24 -o eth0 -j ACCEPT
iptables -t nat -A POSTROUTING -s 192.168.20.0/24 -o eth0 -j MASQUERADE

# Client isolation: prevent guest devices from seeing each other
ebtables -A FORWARD --logical-in br-guest -o ! br-guest -j ACCEPT
ebtables -A FORWARD --logical-in br-guest -j DROP

echo "[+] Guest Wi-Fi isolation configured."
echo "    Gaming VLAN 10: 192.168.10.0/24 — protected"
echo "    Guest VLAN 20:  192.168.20.0/24 — isolated"
