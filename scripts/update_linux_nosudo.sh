#!/usr/bin/env bash
# Rootless (No-Sudo) Linux Installer & Updater for CCS Sleep Studio
# Can be run by any standard user without sudo privileges:
#   curl -fsSL https://raw.githubusercontent.com/arunsasidharan84/CCS_SleepStudio/main/scripts/update_linux_nosudo.sh | bash
# Or with a local .deb / .rpm file:
#   bash update_linux_nosudo.sh /path/to/CCSSleepStudio-linux-amd64.deb

set -euo pipefail

PKG_FILE="${1:-}"
EXTRACT_DIR="$(mktemp -d /tmp/ccs_sleep_extract.XXXXXX)"
DL_FILE=""

cleanup() {
  rm -rf "$EXTRACT_DIR" 2>/dev/null || true
  if [ -n "$DL_FILE" ] && [ -f "$DL_FILE" ]; then
    rm -f "$DL_FILE" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ -z "$PKG_FILE" ]; then
  echo "=== Fetching latest CCS Sleep Studio release from GitHub ==="
  ASSET_NAME="CCSSleepStudio-linux-amd64.deb"
  if [ -f /etc/os-release ] && grep -qiE 'rhel|centos|almalinux|rocky|fedora|suse' /etc/os-release; then
    ASSET_NAME="CCSSleepStudio-linux-x86_64.rpm"
  elif command -v rpm2cpio >/dev/null 2>&1 && ! command -v dpkg-deb >/dev/null 2>&1; then
    ASSET_NAME="CCSSleepStudio-linux-x86_64.rpm"
  fi

  DL_URL="https://github.com/arunsasidharan84/CCS_SleepStudio/releases/latest/download/$ASSET_NAME"
  DL_FILE="/tmp/$ASSET_NAME"
  echo "Downloading $DL_URL ..."
  curl -fL "$DL_URL" -o "$DL_FILE"
  PKG_FILE="$DL_FILE"
fi

if [ ! -f "$PKG_FILE" ]; then
  echo "Error: Package file not found: $PKG_FILE" >&2
  exit 1
fi

echo "=== Extracting $PKG_FILE (no sudo required) ==="
case "$PKG_FILE" in
  *.deb)
    if command -v dpkg-deb >/dev/null 2>&1; then
      dpkg-deb -x "$PKG_FILE" "$EXTRACT_DIR"
    elif command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "$PKG_FILE" -O data.tar* | tar -xf - -C "$EXTRACT_DIR"
    else
      (cd "$EXTRACT_DIR" && ar x "$PKG_FILE" && tar -xf data.tar* && rm -f data.tar* control.tar* debian-binary)
    fi
    ;;
  *.rpm)
    if command -v rpm2cpio >/dev/null 2>&1 && command -v cpio >/dev/null 2>&1; then
      (cd "$EXTRACT_DIR" && rpm2cpio "$PKG_FILE" | cpio -idm --quiet)
    elif command -v bsdtar >/dev/null 2>&1; then
      bsdtar -xf "$PKG_FILE" -C "$EXTRACT_DIR"
    else
      echo "Error: rpm2cpio/cpio or bsdtar required to extract .rpm" >&2
      exit 1
    fi
    ;;
  *)
    echo "Error: Unsupported package format (expected .deb or .rpm): $PKG_FILE" >&2
    exit 1
    ;;
esac

NEW_BUNDLE="$EXTRACT_DIR/usr/lib/ccs-sleep-studio"
if [ ! -f "$NEW_BUNDLE/CCSSleepStudio" ]; then
  echo "Error: Extracted package did not contain usr/lib/ccs-sleep-studio/CCSSleepStudio" >&2
  exit 1
fi
chmod +x "$NEW_BUNDLE/CCSSleepStudio" "$NEW_BUNDLE/analyse-nidra" 2>/dev/null || true

can_write_bundle() {
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] && [ -w "$dir" ] || return 1
  local unwritable
  unwritable=$(find "$dir" -type d ! -writable -print -quit 2>/dev/null)
  [ -z "$unwritable" ]
}

ensure_libmpv_link() {
  local bundle="$1"
  if [ -d "$bundle/lib" ]; then
    for sysdir in /usr/lib/x86_64-linux-gnu /usr/lib64 /usr/lib; do
      if [ ! -e "$sysdir/libmpv.so.1" ] && [ -e "$sysdir/libmpv.so.2" ] && [ ! -e "$bundle/lib/libmpv.so.1" ]; then
        ln -sf "$sysdir/libmpv.so.2" "$bundle/lib/libmpv.so.1" 2>/dev/null || true
        break
      fi
    done
  fi
}

USER_SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
USER_BUNDLE="$USER_SHARE/ccs-sleep-studio"

if can_write_bundle "/usr/lib/ccs-sleep-studio"; then
  echo "=== Updating system-wide /usr/lib/ccs-sleep-studio in-place ==="
  (
    umask 0000
    cp -rf --remove-destination "$NEW_BUNDLE/." "/usr/lib/ccs-sleep-studio/"
  )
  chmod -R a+rwX "/usr/lib/ccs-sleep-studio" 2>/dev/null || true
  chmod a+rx "/usr/lib/ccs-sleep-studio/CCSSleepStudio" "/usr/lib/ccs-sleep-studio/analyse-nidra" 2>/dev/null || true
  ensure_libmpv_link "/usr/lib/ccs-sleep-studio"
  echo "=== Updated /usr/lib/ccs-sleep-studio successfully! ==="
else
  echo "=== Installing per-user update to $USER_BUNDLE ==="
  USER_BIN_DIR="$HOME/.local/bin"
  USER_APP_DIR="$USER_SHARE/applications"
  USER_ICON_DIR="$USER_SHARE/icons/hicolor/256x256/apps"

  mkdir -p "$USER_BUNDLE" "$USER_BIN_DIR" "$USER_APP_DIR" "$USER_ICON_DIR"
  cp -rf --remove-destination "$NEW_BUNDLE/." "$USER_BUNDLE/"
  chmod -R u+rwX "$USER_BUNDLE" 2>/dev/null || true
  chmod +x "$USER_BUNDLE/CCSSleepStudio" "$USER_BUNDLE/analyse-nidra" 2>/dev/null || true
  ensure_libmpv_link "$USER_BUNDLE"

  ln -sf "$USER_BUNDLE/CCSSleepStudio" "$USER_BIN_DIR/ccs-sleep-studio"

  if [ -f "$EXTRACT_DIR/usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png" ]; then
    cp -f "$EXTRACT_DIR/usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png" \
      "$USER_ICON_DIR/ccs-sleep-studio.png" 2>/dev/null || true
  fi

  DESKTOP_SRC="$EXTRACT_DIR/usr/share/applications/ccs-sleep-studio.desktop"
  if [ -f "$DESKTOP_SRC" ]; then
    sed "s|^Exec=.*|Exec=$USER_BUNDLE/CCSSleepStudio %F|g" "$DESKTOP_SRC" \
      > "$USER_APP_DIR/ccs-sleep-studio.desktop"
    chmod 755 "$USER_APP_DIR/ccs-sleep-studio.desktop" 2>/dev/null || true

    if [ -d "$HOME/Desktop" ]; then
      cp -f "$USER_APP_DIR/ccs-sleep-studio.desktop" "$HOME/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chmod 755 "$HOME/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
    fi
  fi

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$USER_APP_DIR" 2>/dev/null || true
  fi

  echo "=== Installed to $USER_BUNDLE successfully! ==="
  echo "Desktop & Application Menu shortcuts updated for $(whoami)."
fi
