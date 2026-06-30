#!/bin/bash
# ============================================================
# VPN server setup script (Amazon Linux 2023)
# ============================================================
# [About this script]
#   It is embedded as the UserData of the EC2 stack (04_ec2.yaml) and
#   runs automatically at the first boot of EC2.
#
#   This file is a "readable reference version."
#   What actually runs is the copy inside CloudFormation's UserData.
#
# [How to check execution logs] (after connecting via SSM Session Manager)
#   sudo cat /var/log/cloud-init-output.log  # CloudFormation execution log
#   sudo cat /var/log/vpn-setup.log          # this script's custom log
#
# [Main differences from Ubuntu]
#   Package management: apt → dnf
#   Firewall:          ufw → firewalld
#   SSH log:           /var/log/auth.log → /var/log/secure
#   SSM Agent:         needs install → pre-installed
# ============================================================

set -e   # stop immediately on error
set -x   # log executed commands (for debugging)

PROJECT="personal-vpn"   # ← change here if needed
LOG_FILE="/var/log/vpn-setup.log"

echo "=== VPN Server Setup Start ===" | tee $LOG_FILE
echo "Timestamp: $(date)" | tee -a $LOG_FILE
echo "Project: $PROJECT" | tee -a $LOG_FILE

# ============================================================
# Step 1: Update system packages
# ============================================================
# dnf: the package manager for Amazon Linux 2023 / RHEL / Fedora family
# Equivalent to apt-get on Ubuntu
# -y: auto-answer "yes" to all confirmation prompts
dnf update -y

# ============================================================
# Step 2: Install required packages
# ============================================================
# wireguard-tools : WireGuard VPN configuration/management CLI tools
#                   (the kernel module ships with AL2023)
# fail2ban        : watches logs and bans brute-force attacker IPs
# firewalld       : AL2023's default firewall management tool
#                   (equivalent to ufw on Ubuntu)
# qrencode        : generate QR codes from text (simplifies WireGuard phone setup)
# curl            : download files over HTTP
# jq              : parse/format JSON data
dnf install -y \
  wireguard-tools \
  fail2ban \
  firewalld \
  qrencode \
  curl \
  jq

# Install OpenVPN
# From the AL2023 standard repo if available, otherwise install manually
if dnf install -y openvpn; then
  echo "OpenVPN: installed from standard repo" | tee -a $LOG_FILE
else
  echo "OpenVPN: not in standard repo" | tee -a $LOG_FILE
  echo "  → See docs/wireguard_openvpn_setup.md for manual installation steps" | tee -a $LOG_FILE
fi

# easy-rsa (OpenVPN certificate management tool)
if dnf install -y easy-rsa; then
  echo "easy-rsa: installed from standard repo" | tee -a $LOG_FILE
else
  # If not in the AL2023 standard repo, install directly from GitHub
  echo "easy-rsa: installing from GitHub..." | tee -a $LOG_FILE
  EASYRSA_VER="3.1.7"
  curl -fsSL \
    "https://github.com/OpenVPN/easy-rsa/releases/download/v$EASYRSA_VER/EasyRSA-$EASYRSA_VER.tgz" \
    -o /tmp/easyrsa.tgz
  tar xzf /tmp/easyrsa.tgz -C /opt/
  ln -sf /opt/EasyRSA-$EASYRSA_VER/easyrsa /usr/local/bin/easyrsa
  chmod +x /usr/local/bin/easyrsa
  echo "easy-rsa: installed v$EASYRSA_VER from GitHub" | tee -a $LOG_FILE
fi

# ============================================================
# Step 3: Confirm SSM Agent (pre-installed on Amazon Linux 2023)
# ============================================================
# SSM Agent: the process EC2 uses to talk to AWS Systems Manager (SSM)
# While it runs, you can reach EC2 via SSM Session Manager without SSH
#
# AL2023 ships the SSM Agent pre-installed, so we just
# enable and start it
systemctl enable --now amazon-ssm-agent
SSM_STATUS=$(systemctl is-active amazon-ssm-agent)
echo "SSM Agent: $SSM_STATUS" | tee -a $LOG_FILE

# ============================================================
# Step 4: Enable IP forwarding (packet forwarding)
# ============================================================
# [Why IP forwarding is needed]
#   A VPN server "relays internet access on behalf of clients."
#   To forward packets received from clients to the internet, the Linux
#   kernel's "IP forwarding" feature must be enabled.
#
#   Default is disabled (0) → change to enabled (1).
#   Writing it to /etc/sysctl.conf keeps the setting across reboots.
cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
# VPN packet forwarding (added by vpn setup script)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL_EOF

# Apply immediately (no reboot needed)
sysctl -p
echo "IP forwarding: enabled" | tee -a $LOG_FILE

# ============================================================
# Step 5: firewalld configuration (host firewall)
# ============================================================
# [What firewalld is]
#   A tool that manages the Linux firewall with zone-based rules via GUI/CLI.
#   The default firewall management tool on AL2023.
#   (Equivalent to ufw on Ubuntu, but more capable.)
#
# [What a zone is]
#   firewalld manages rules using the concept of "zones."
#   Rules are often added to the default zone "public."
#
# firewall-cmd: firewalld's command-line tool
# --permanent: keep the setting across reboots (without it, a reboot resets it)
# --reload: reload and apply the settings

systemctl enable --now firewalld

# Allow the WireGuard VPN port (UDP 51820)
firewall-cmd --permanent --add-port=51820/udp

# Allow the OpenVPN port (TCP 443: uses the HTTPS port, so it passes most firewalls)
firewall-cmd --permanent --add-port=443/tcp

# Enable masquerade (NAT)
# Translate the VPN client's IP to EC2's public IP for outbound traffic
# Without this, VPN clients cannot reach the internet
firewall-cmd --permanent --add-masquerade

# Reload and apply
firewall-cmd --reload

echo "firewalld: $(systemctl is-active firewalld)" | tee -a $LOG_FILE
echo "  Ports: 51820/udp (WireGuard), 443/tcp (OpenVPN)" | tee -a $LOG_FILE

# ============================================================
# Step 6: fail2ban configuration (intrusion protection)
# ============================================================
# [What fail2ban is]
#   A tool that watches log files and automatically blocks (via firewalld)
#   IP addresses that fail authentication a set number of times.
#   Protects against brute-force (password-guessing) attacks.
#
# [What /var/log/secure is]
#   The SSH auth log on AL2023 / the RHEL family
#   (equivalent to /var/log/auth.log on Ubuntu)
#
# Settings:
#   bantime = 3600  : how long to ban (seconds) = 1 hour
#   findtime = 600  : within this window (seconds)
#   maxretry = 3    : ban after this many failures
cat > /etc/fail2ban/jail.local << 'FAIL2BAN_EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = ssh
logpath  = /var/log/secure
maxretry = 3
FAIL2BAN_EOF

systemctl enable --now fail2ban
echo "fail2ban: $(systemctl is-active fail2ban)" | tee -a $LOG_FILE

# ============================================================
# Step 7: Automatic security updates
# ============================================================
# [What dnf-automatic is]
#   A tool that automatically applies Linux security patches.
#   Once a day, it auto-installs any available security updates.
#
# Settings:
#   upgrade_type = security: auto-apply only security-related updates
#   apply_updates = yes: enable auto-apply (default is no, so change it)
dnf install -y dnf-automatic
sed -i 's/upgrade_type = default/upgrade_type = security/' /etc/dnf/automatic.conf
sed -i 's/apply_updates = no/apply_updates = yes/' /etc/dnf/automatic.conf

# Enable the timer (runs periodically via a systemd timer)
systemctl enable --now dnf-automatic.timer
echo "dnf-automatic: enabled" | tee -a $LOG_FILE

# ============================================================
# Completion log
# ============================================================
echo "" | tee -a $LOG_FILE
echo "=== Setup Summary ===" | tee -a $LOG_FILE
echo "Completed at: $(date)" | tee -a $LOG_FILE
echo "OS: $(grep PRETTY_NAME /etc/os-release | cut -d'=' -f2 | tr -d '\"')" | tee -a $LOG_FILE
echo "Kernel: $(uname -r)" | tee -a $LOG_FILE
echo "SSM Agent: $(systemctl is-active amazon-ssm-agent)" | tee -a $LOG_FILE
echo "firewalld: $(systemctl is-active firewalld)" | tee -a $LOG_FILE
echo "fail2ban: $(systemctl is-active fail2ban)" | tee -a $LOG_FILE
echo "WireGuard: $(wg --version 2>/dev/null || echo 'not found')" | tee -a $LOG_FILE
echo "OpenVPN: $(openvpn --version 2>/dev/null | head -1 || echo 'not found - see docs/wireguard_openvpn_setup.md')" | tee -a $LOG_FILE
echo "=== Setup Complete ===" | tee -a $LOG_FILE
