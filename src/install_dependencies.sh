#!/usr/bin/env bash
# install_dependencies.sh - Installs required packages for Ubuntu/Debian and Oracle Linux/RHEL
set -euo pipefail

OS_ID="$(. /etc/os-release 2>/dev/null; echo "${ID:-unknown}")"
PKGS_APT=(openssh-client sshpass expect screen)
PKGS_DNF=(openssh-clients sshpass expect screen)

if [[ "$OS_ID" =~ (ubuntu|debian) ]]; then
  echo "[INFO] Detected Ubuntu/Debian. Using apt-get..."
  sudo apt-get update
  sudo apt-get install -y "${PKGS_APT[@]}"
elif [[ "$OS_ID" =~ (ol|oracle|rhel|centos|rocky|almalinux|fedora) ]]; then
  echo "[INFO] Detected RHEL-family. Using dnf/yum..."
  sudo dnf install -y "${PKGS_DNF[@]}" 2>/dev/null || sudo yum install -y "${PKGS_DNF[@]}"
else
  echo "[WARN] Unrecognized OS: ${OS_ID}"
  echo "       Please install manually: openssh-client/openssh-clients sshpass expect screen"
fi

echo "[OK] Dependencies installed."
