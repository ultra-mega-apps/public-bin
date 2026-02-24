#!/usr/bin/env bash
set -euo pipefail

# Unattended Auto Upgrade
apt-get update
apt-get install -y unattended-upgrades

dpkg-reconfigure -plow unattended-upgrades

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
systemctl status unattended-upgrades --no-pager || true

systemctl list-timers --all | egrep 'apt-daily|unattended' || true
tail -n 80 /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null || true

grep -R --line-number 'Unattended-Upgrade::Allowed-Origins\|Origins-Pattern\|Automatic-Reboot\|Remove-Unused\|AutoFixInterrupted' /etc/apt/apt.conf.d/\* | head -n 200

# Automatic Restarts and Ubuntu Pro
set -euo pipefail

mkdir -p /root/config-backups/etc/apt/apt.conf.d/
cp -a /etc/apt/apt.conf.d/50unattended-upgrades /root/config-backups/etc/apt/apt.conf.d/50unattended-upgrades.bak.$(date +%F_%H%M%S)
cp -a /etc/apt/apt.conf.d/20auto-upgrades /root/config-backups/etc/apt/apt.conf.d/20auto-upgrades.bak.$(date +%F\_%H%M%S) 2>/dev/null || true

cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
// Managed config (reproducible)

Unattended-Upgrade::Allowed-Origins {
"${distro_id}:${distro_codename}";
"${distro_id}:${distro_codename}-security";
"${distro_id}:${distro_codename}-updates";

    // Ubuntu Pro / ESM (if enabled)
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESMApps:${distro_codename}-apps-updates";
    "${distro_id}ESM:${distro_codename}-infra-security";
    "${distro_id}ESM:${distro_codename}-infra-updates";

};

Unattended-Upgrade::Package-Blacklist {
};

Unattended-Upgrade::DevRelease "auto";

Unattended-Upgrade::AutoFixInterruptedDpkg "true";

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Reboot automatically if /var/run/reboot-required exists.
// 06:00 UTC-3 == 09:00 UTC (server currently logs in UTC)
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "09:00";
EOF

systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
systemctl enable --now unattended-upgrades.service

unattended-upgrades --dry-run --debug | tail -n 120 || true
