#!/usr/bin/env bash
# install_dependencies.sh
set -euo pipefail
OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
if [[ "$OS_ID" =~ (ubuntu|debian) ]]; then
  sudo apt-get update
  sudo apt-get install -y openssh-client sshpass expect screen
elif [[ "$OS_ID" =~ (ol|oracle|rhel|centos|rocky|almalinux|fedora) ]]; then
  sudo dnf install -y openssh-clients sshpass expect screen 2>/dev/null \
    || sudo yum install -y openssh-clients sshpass expect screen
else
  echo "[WARN] Unknown OS '${OS_ID}'. Install manually: openssh-client sshpass expect screen"
fi
echo "[OK] Dependencies installed."
