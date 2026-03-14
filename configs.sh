#!/usr/bin/env bash
set -euo pipefail

apt-get update
apt-get install -y linux-tools-common linux-tools-$(uname -r) || true
cpupower frequency-set -g performance
