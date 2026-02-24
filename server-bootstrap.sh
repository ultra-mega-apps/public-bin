#!/usr/bin/env bash
set -euo pipefail

# tailscale
curl -fsSL https://tailscale.com/install.sh | sh && tailscale up --advertise-exit-node
tailscale set --auto-update

# ubuntu autoupgrade
curl -fsSL 'https://raw.githubusercontent.com/ultra-mega-apps/public-bin/refs/heads/main/ubuntu-pro-unattended-upgrade.sh' | bash

# ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0
ufw allow in on eth0 to any port 80 proto tcp
ufw allow in on eth0 to any port 443 proto tcp
ufw --force enable
echo "try to connect to ssh over wan to test firewall"
echo
echo

# node24
curl -fsSL https://deb.nodesource.com/setup_24.x | bash -

# common apps
apt update
apt install -y \
  nodejs \
  gh \
  rclone \
  net-tools 

# gh git config
read -p -s 'Enter user.email: ' GIT_USER_EMAIL
read -p -s 'Enter user.name: ' GIT_USER_NAME
git config --global user.email "$GIT_USER_EMAIL"
git config --global user.name "$GIT_USER_NAME"
gh auth login
gh repo clone ultra-mega-apps/bin ~/bin

# .bashrc
cp ~/.bashrc ~/.bashrc.before.server-bootstrap.bak
sed -i 's/HISTSIZE=1000/HISTSIZE=10000/g' .bashrc
sed -i 's/HISTFILESIZE=2000/HISTFILESIZE=20000/g' .bashrc
sed -i 's/#force_color_prompt/force_color_prompt/g' .bashrc
sed -i 's/01;32m/01;95m/g' .bashrc

touch ~/.bash_aliases
echo $'alias list=\'ls -lkhp\'' >> ~/.bash_aliases
echo $'alias lista=\'ls -lkhap\'' >> ~/.bash_aliases

echo >> .bashrc
echo 'export PATH="~/bin:$PATH"' >> .bashrc

source ~/.bashrc
