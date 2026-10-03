#!/usr/bin/env bash
# ==============================================================================
# CCS Sleep Studio - Enterprise Linux Multi-User Server Installer
# Repository: https://github.com/arunsasidharan84/CCS_SleepStudio
# ==============================================================================
set -euo pipefail

GITHUB_REPO="arunsasidharan84/CCS_SleepStudio"
PACKAGE_VARIANT="${1:-full}" # "full" or "lite"

echo "======================================================================"
echo "          CCS Sleep Studio - Linux Server Installation Setup          "
echo "======================================================================"

if [[ $EUID -ne 0 ]]; then
  echo "Error: This installer requires administrative privileges." >&2
  echo "Please rerun with sudo: sudo bash $0 [full|lite]" >&2
  exit 1
fi

ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" ]]; then
  echo "Error: CCS Sleep Studio currently supports x86_64 architecture (detected: $ARCH)." >&2
  exit 1
fi

# Detect Linux Distribution
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  DISTRO_ID=${ID:-linux}
  DISTRO_LIKE=${ID_LIKE:-""}
else
  echo "Warning: Unable to determine Linux distribution from /etc/os-release."
  DISTRO_ID="unknown"
  DISTRO_LIKE=""
fi

IS_RPM=false
IS_DEB=false

if [[ "$DISTRO_ID" =~ ^(rhel|centos|almalinux|rocky|fedora|ol|amzn)$ ]] || [[ "$DISTRO_LIKE" =~ (rhel|fedora|centos) ]]; then
  IS_RPM=true
elif [[ "$DISTRO_ID" =~ ^(ubuntu|debian|linuxmint|pop)$ ]] || [[ "$DISTRO_LIKE" =~ (ubuntu|debian) ]]; then
  IS_DEB=true
elif command -v dnf >/dev/null 2>&1 || command -v rpm >/dev/null 2>&1; then
  IS_RPM=true
elif command -v apt-get >/dev/null 2>&1 || command -v dpkg >/dev/null 2>&1; then
  IS_DEB=true
else
  echo "Error: Unsupported package manager. Requires dnf/rpm (EL/Fedora) or apt/dpkg (Ubuntu/Debian)." >&2
  exit 1
fi

echo "--> Target Platform : $DISTRO_ID (arch: $ARCH)"
echo "--> Package Variant : $PACKAGE_VARIANT"

# Step 1: Repository & System Dependency Setup
echo "--> Preparing repository and media dependencies..."
if [[ "$IS_RPM" = true ]]; then
  # Enable EPEL and CRB / CodeReady / PowerTools if available on EL systems
  if command -v dnf >/dev/null 2>&1; then
    if ! rpm -q epel-release >/dev/null 2>&1; then
      echo "    Installing epel-release repository for multimedia libraries..."
      dnf install -y epel-release 2>/dev/null || true
    fi
    # Enable CRB / PowerTools for supplementary dependencies
    dnf config-manager --set-enabled crb 2>/dev/null || \
    dnf config-manager --set-enabled powertools 2>/dev/null || true
    
    # Pre-install mpv-libs if available
    echo "    Checking for mpv-libs package..."
    dnf install -y mpv-libs 2>/dev/null || true
  fi
elif [[ "$IS_DEB" = true ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends libmpv1 libmpv2 2>/dev/null || true
  fi
fi

# Step 2: Determine package URL from GitHub Releases
echo "--> Fetching latest release information from GitHub..."
RELEASE_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
API_RESPONSE=$(curl -fsSL "$RELEASE_API_URL" 2>/dev/null || true)

if [[ -z "$API_RESPONSE" ]]; then
  # Fallback to releases list with semantic version sorting
  echo "    Checking releases index..."
  API_RESPONSE=$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases" 2>/dev/null || true)
fi

DOWNLOAD_URL=""
LATEST_TAG=""

if [[ "$IS_RPM" = true ]]; then
  RPM_ASSET_NAME="CCSSleepStudio-linux-x86_64.rpm"
  if [[ "$PACKAGE_VARIANT" == "lite" ]]; then
    RPM_ASSET_NAME="CCSSleepStudio-lite-linux-x86_64.rpm"
  fi

  if [[ -n "$API_RESPONSE" ]]; then
    DOWNLOAD_URL=$(echo "$API_RESPONSE" | grep -o "https://[^\"]*${RPM_ASSET_NAME}" | head -n 1 || true)
    LATEST_TAG=$(echo "$API_RESPONSE" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
  fi

  if [[ -z "$DOWNLOAD_URL" ]]; then
    # Direct fallback download URL
    LATEST_TAG="v1.24.1"
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${RPM_ASSET_NAME}"
  fi

  PKG_TMP="/tmp/${RPM_ASSET_NAME}"
elif [[ "$IS_DEB" = true ]]; then
  DEB_ASSET_NAME="CCSSleepStudio-linux-amd64.deb"
  if [[ "$PACKAGE_VARIANT" == "lite" ]]; then
    DEB_ASSET_NAME="CCSSleepStudio-lite-linux-amd64.deb"
  fi

  if [[ -n "$API_RESPONSE" ]]; then
    DOWNLOAD_URL=$(echo "$API_RESPONSE" | grep -o "https://[^\"]*${DEB_ASSET_NAME}" | head -n 1 || true)
    LATEST_TAG=$(echo "$API_RESPONSE" | grep -m1 '"tag_name":' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
  fi

  if [[ -z "$DOWNLOAD_URL" ]]; then
    LATEST_TAG="v1.24.1"
    DOWNLOAD_URL="https://github.com/${GITHUB_REPO}/releases/download/${LATEST_TAG}/${DEB_ASSET_NAME}"
  fi

  PKG_TMP="/tmp/${DEB_ASSET_NAME}"
fi

echo "--> Latest Release  : ${LATEST_TAG:-v1.24.1}"
echo "--> Downloading package from: $DOWNLOAD_URL"
curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$PKG_TMP"

# Step 3: Install Package
echo "--> Installing package..."
if [[ "$IS_RPM" = true ]]; then
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y "$PKG_TMP"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$PKG_TMP"
  else
    rpm -Uvh --replacepkgs "$PKG_TMP"
  fi
elif [[ "$IS_DEB" = true ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y "$PKG_TMP"
  else
    dpkg -i "$PKG_TMP" || apt-get install -f -y
  fi
fi

# Clean up download
rm -f "$PKG_TMP"

# Step 4: Multi-User Desktop & System Integration
echo "--> Configuring multi-user desktop integration across all user accounts..."

# 4a. Update desktop and icon databases
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi

# 4b. Ensure /usr/share/pixmaps has the icon
if [[ -f /usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png ]] && [[ ! -f /usr/share/pixmaps/ccs-sleep-studio.png ]]; then
  mkdir -p /usr/share/pixmaps
  cp -f /usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png /usr/share/pixmaps/ccs-sleep-studio.png
fi

# 4c. Setup skeleton directory so every future user gets an executable desktop launcher
LAUNCHER="/usr/share/applications/ccs-sleep-studio.desktop"
if [[ -d /etc/skel && -f "$LAUNCHER" ]]; then
  mkdir -p /etc/skel/Desktop
  cp -f "$LAUNCHER" /etc/skel/Desktop/ccs-sleep-studio.desktop
  chmod 755 /etc/skel/Desktop/ccs-sleep-studio.desktop
fi

# 4d. Propagate to all existing user accounts with mode 755 and user ownership
USER_COUNT=0
if [[ -f "$LAUNCHER" ]]; then
  while IFS=: read -r uname _ uid gid _ homedir _; do
    if [[ "$uid" -ge 1000 ]] 2>/dev/null && [[ -d "$homedir" ]]; then
      # If user has a Desktop directory or VNC session, deploy launcher
      USER_DESKTOP="$homedir/Desktop"
      if [[ -d "$USER_DESKTOP" ]]; then
        cp -f "$LAUNCHER" "$USER_DESKTOP/ccs-sleep-studio.desktop"
        chmod 755 "$USER_DESKTOP/ccs-sleep-studio.desktop"
        chown "$uid:$gid" "$USER_DESKTOP/ccs-sleep-studio.desktop" 2>/dev/null || true
        USER_COUNT=$((USER_COUNT + 1))
      fi
    fi
  done < <(getent passwd 2>/dev/null || cat /etc/passwd)

  # Also scan common multi-user home mounts (/serverdata/ccshome, /home, /export/home)
  for udir in /serverdata/ccshome/* /home/* /export/home/* /data/home/*; do
    if [[ -d "$udir/Desktop" ]]; then
      cp -f "$LAUNCHER" "$udir/Desktop/ccs-sleep-studio.desktop"
      chmod 755 "$udir/Desktop/ccs-sleep-studio.desktop"
      OWNER=$(stat -c '%u:%g' "$udir" 2>/dev/null || true)
      if [[ -n "$OWNER" ]]; then
        chown "$OWNER" "$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      fi
    fi
  done
fi

echo "--> Propagated desktop shortcut to $USER_COUNT user accounts."

# Step 5: Verification
echo "--> Verifying installation..."
if [[ -x /usr/bin/ccs-sleep-studio ]]; then
  echo "    [OK] Main binary: /usr/bin/ccs-sleep-studio"
else
  echo "    [WARN] /usr/bin/ccs-sleep-studio not found or not executable"
fi

if [[ -x /usr/lib/ccs-sleep-studio/analyse-nidra ]]; then
  CLI_VER=$(/usr/lib/ccs-sleep-studio/analyse-nidra --version 2>&1 || true)
  echo "    [OK] AnalyseNidra engine: $CLI_VER"
else
  echo "    [WARN] analyse-nidra engine not found"
fi

if [[ -d /usr/lib/ccs-sleep-studio/assets/models ]]; then
  MODEL_COUNT=$(find /usr/lib/ccs-sleep-studio/assets/models -maxdepth 1 -type d | wc -l)
  echo "    [OK] AI Autoscory models present ($MODEL_COUNT model suites bundled)"
fi

echo ""
echo "======================================================================"
echo "  CCS Sleep Studio installed successfully for all server users!       "
echo "======================================================================"
echo "  • Desktop Launch: Double-click 'CCS Sleep Studio' on your Desktop. "
echo "  • Menu Launch   : Applications > Science / Medical > CCS Sleep Studio"
echo "  • Terminal      : Run 'ccs-sleep-studio' from any shell.           "
echo "======================================================================"
