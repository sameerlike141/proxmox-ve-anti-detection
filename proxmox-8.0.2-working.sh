#!/usr/bin/env bash
#
# build-proxmox-anti-detection.sh
#
# This script automates building a patched Proxmox QEMU (pve-qemu-kvm)
# to evade some anti-VM detections. Tested on Proxmox VE 8.0.2.
#
# DISCLAIMER:
#   1. This script changes APT sources to "no-subscription" & Dev repos,
#      overriding your official or enterprise repos.
#   2. It modifies /etc/apt/sources.list and /etc/apt/sources.list.d/pve-enterprise.list.
#   3. It installs dev tools, clones pve-qemu at a specific commit, applies a patch,
#      and builds a .deb. This .deb replaces your default QEMU in Proxmox.
#   4. This is for demonstration or advanced usage ONLY. Use at your own risk.
#
# Steps performed:
#   1) Backup existing APT sources
#   2) Create new APT sources (USTC mirrors)
#   3) apt update
#   4) apt install dev dependencies
#   5) Clone pve-qemu & reset to commit
#   6) mk-build-deps
#   7) Download 001-anti-detection.patch
#   8) Insert patch line in debian/rules (automated sed injection)
#   9) Move patch out of qemu/, remove qemu submodule dir, reinit submodule
#   10) Move patch back, then make clean & make
#
# The final .deb should appear in the same folder if everything succeeded.
# Then you can install it with dpkg -i or scp it to another PVE node.

set -e  # Exit on error

# --- 0) Must be root or equivalent ---
if [ "$(id -u)" != "0" ]; then
  echo "ERROR: This script must be run as root (uid 0)."
  exit 1
fi

echo ">>> This script will override your apt sources and build a custom QEMU .deb."
echo ">>> Press Ctrl+C now if you do not want to proceed!"
sleep 5

# --- 1) Backup existing apt sources ---
echo ">>> Backing up existing apt sources..."
if [ -f /etc/apt/sources.list ]; then
  mv /etc/apt/sources.list /etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)
fi
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
  mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak.$(date +%Y%m%d%H%M%S)
fi

# --- 2) Create new sources.list (USTC mirrors for Bookworm + Proxmox 8 dev repos) ---
cat <<EOF > /etc/apt/sources.list
deb https://mirrors.ustc.edu.cn/debian/ bookworm main contrib non-free
deb https://mirrors.ustc.edu.cn/debian/ bookworm-updates main contrib non-free
deb https://mirrors.ustc.edu.cn/debian/ bookworm-backports main contrib non-free
deb https://mirrors.ustc.edu.cn/debian-security bookworm-security main contrib non-free

# Proxmox VE no-subscription repository
deb https://mirrors.ustc.edu.cn/proxmox/debian bookworm pve-no-subscription

# Ceph Pacific repository
deb https://mirrors.ustc.edu.cn/proxmox/debian/ceph-pacific bookworm main

# Development repository (required for building)
deb https://mirrors.ustc.edu.cn/proxmox/debian/devel bookworm main
EOF

echo ">>> Updating package lists..."
apt update -y

# --- 3) Install dev packages ---
echo ">>> Installing dev packages..."
apt install -y devscripts equivs dpkg-dev build-essential git wget nano

# --- 4) Clone pve-qemu & reset to given commit ---
cd /opt || mkdir -p /opt && cd /opt
if [ -d pve-qemu ]; then
  echo ">>> 'pve-qemu' directory already exists. Using it."
else
  echo ">>> Cloning pve-qemu repository..."
  git clone git://git.proxmox.com/git/pve-qemu.git
fi
cd pve-qemu

echo ">>> Resetting to commit 409db0cd7bdc833e4a09d39492b319426029aa92..."
git fetch --all
git reset --hard 409db0cd7bdc833e4a09d39492b319426029aa92

# --- 5) Build dependencies ---
echo ">>> Installing build dependencies via mk-build-deps..."
mk-build-deps --install

# --- 6) Download anti-detection patch ---
echo ">>> Downloading 001-anti-detection.patch..."
mkdir -p qemu
wget -O qemu/001-anti-detection.patch \
  "https://github.com/zhaodice/proxmox-ve-anti-detection/raw/main/001-anti-detection.patch"

# --- 7) Inject patch line into debian/rules automatically if not already inserted ---
PATCH_STRING='patch -p1 < 001-anti-detection.patch'
RULES_FILE='debian/rules'

if ! grep -q "$PATCH_STRING" "$RULES_FILE"; then
  echo ">>> Inserting patch command into debian/rules..."
  # Insert right before the "./configure \" line or near the '# guest-agent...' line
  sed -i '/# guest-agent is only required for guest systems/i \
# [Inject] Anti-Detection Patch\
\tpatch -p1 < 001-anti-detection.patch\
' "$RULES_FILE"
else
  echo ">>> The patch line seems already present in debian/rules. Skipping sed injection."
fi

# --- 8) Fix submodule by removing qemu dir, re-initializing, then restoring patch ---
echo ">>> Moving patch out, removing submodule folder, re-initializing..."
mv qemu/001-anti-detection.patch /tmp/ 2>/dev/null || true
rm -rf qemu
git submodule update --init --recursive

echo ">>> Restoring patch to qemu/..."
cp /tmp/001-anti-detection.patch qemu/

# --- 9) Build (make clean && make) ---
echo ">>> Starting build (make clean && make)..."
make clean
make

echo ""
echo "======================================================================"
echo ">>> Build process completed. If successful, a .deb package like"
echo ">>> 'pve-qemu-kvm_8.0.2-3_amd64.deb' should be present in this folder."
echo ">>> You can install it on your Proxmox host with:"
echo ""
echo "      dpkg -i pve-qemu-kvm_..._amd64.deb"
echo ""
echo ">>> NOTE: If building in a VM, copy that .deb to your main PVE host first."
echo "======================================================================"
