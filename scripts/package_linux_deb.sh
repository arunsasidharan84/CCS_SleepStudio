#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <flutter-bundle> <output.deb> <full|lite>" >&2
  exit 2
fi

bundle_dir=$1
output_deb=$2
variant=$3
repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

if [[ ! -x "$bundle_dir/CCSSleepStudio" ]]; then
  echo "Linux bundle executable not found: $bundle_dir/CCSSleepStudio" >&2
  exit 1
fi
if [[ "$variant" != "full" && "$variant" != "lite" ]]; then
  echo "Variant must be 'full' or 'lite'." >&2
  exit 2
fi

version=$(awk '/^version:/ {print $2; exit}' "$repo_root/frontend/pubspec.yaml")
version=${version%%+*}
package_name=ccs-sleep-studio
display_name="CCS Sleep Studio"
conflicts=ccs-sleep-studio-lite
description="Sleep EEG visualization, scoring, and quantitative analysis"
if [[ "$variant" == "lite" ]]; then
  package_name=ccs-sleep-studio-lite
  display_name="CCS Sleep Studio Lite"
  conflicts=ccs-sleep-studio
  description="Sleep EEG visualization, manual scoring, and quantitative analysis"
fi

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
package_root="$work_dir/package"
install_dir="$package_root/usr/lib/ccs-sleep-studio"

mkdir -p \
  "$package_root/DEBIAN" \
  "$install_dir" \
  "$package_root/usr/bin" \
  "$package_root/usr/share/applications" \
  "$package_root/usr/share/pixmaps" \
  "$package_root/usr/share/icons/hicolor/256x256/apps"
cp -a "$bundle_dir/." "$install_dir/"
ln -s ../lib/ccs-sleep-studio/CCSSleepStudio "$package_root/usr/bin/ccs-sleep-studio"
install -m 0644 "$repo_root/frontend/assets/logo.png" \
  "$package_root/usr/share/pixmaps/ccs-sleep-studio.png"
install -m 0644 "$repo_root/frontend/assets/logo.png" \
  "$package_root/usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png"

installed_size=$(du -sk "$package_root/usr" | awk '{print $1}')
cat > "$package_root/DEBIAN/control" <<EOF
Package: $package_name
Version: $version
Section: science
Priority: optional
Architecture: amd64
Installed-Size: $installed_size
Depends: libgtk-3-0, libblkid1, liblzma5
Recommends: libmpv1 | libmpv2
Conflicts: $conflicts
Maintainer: CCS Sleep Studio Project <noreply@github.com>
Homepage: https://github.com/arunsasidharan84/CCS-Sleep-Studio
Description: $description
 CCS Sleep Studio is a desktop application for polysomnography review,
 sleep staging, and advanced quantitative EEG analysis.
EOF

cat > "$package_root/usr/share/applications/ccs-sleep-studio.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$display_name
Comment=$description
Exec=/usr/bin/ccs-sleep-studio %F
Icon=ccs-sleep-studio
Terminal=false
Categories=Science;MedicalSoftware;Education;Utility;DataVisualization;
Keywords=sleep;eeg;psg;polysomnography;scoring;hypnogram;neuroscience;
StartupNotify=true
StartupWMClass=CCSSleepStudio
MimeType=application/octet-stream;application/x-edf;
EOF

cat > "$package_root/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e

# 1. libmpv compatibility symlink
for dir in /usr/lib/x86_64-linux-gnu /usr/lib; do
  if [ ! -e "$dir/libmpv.so.1" ] && [ -e "$dir/libmpv.so.2" ]; then
    ln -sf libmpv.so.2 "$dir/libmpv.so.1" || true
  fi
done

# 2. Update desktop database and icon caches
if which update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications || true
fi
if which gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi

# 3. Multi-user desktop launcher setup
if [ -d /etc/skel ]; then
  mkdir -p /etc/skel/Desktop
  cp -f /usr/share/applications/ccs-sleep-studio.desktop /etc/skel/Desktop/
  chmod 755 /etc/skel/Desktop/ccs-sleep-studio.desktop 2>/dev/null || true
fi

launcher=/usr/share/applications/ccs-sleep-studio.desktop
if [ -f "$launcher" ]; then
  while IFS=: read -r _ _ uid gid _ homedir _; do
    if [ "$uid" -ge 1000 ] 2>/dev/null && [ -d "$homedir/Desktop" ]; then
      cp -f "$launcher" "$homedir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chmod 755 "$homedir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chown "$uid:$gid" "$homedir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
    fi
  done < /etc/passwd

  for udir in /home/* /serverdata/ccshome/* /export/home/* /data/home/*; do
    if [ -d "$udir/Desktop" ]; then
      cp -f "$launcher" "$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chmod 755 "$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      owner_id=$(stat -c '%u:%g' "$udir" 2>/dev/null || true)
      if [ -n "$owner_id" ]; then
        chown "$owner_id" "$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      fi
    fi
  done
fi
EOF
chmod 0755 "$package_root/DEBIAN/postinst"

cat > "$package_root/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
  for dir in /usr/lib/x86_64-linux-gnu /usr/lib; do
    if [ -L "$dir/libmpv.so.1" ] && [ "$(readlink "$dir/libmpv.so.1")" = "libmpv.so.2" ]; then
      rm -f "$dir/libmpv.so.1" || true
    fi
  done
  rm -f /etc/skel/Desktop/ccs-sleep-studio.desktop
  if which update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications || true
  fi
  if which gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
  fi
fi
EOF
chmod 0755 "$package_root/DEBIAN/postrm"

mkdir -p "$(dirname "$output_deb")"
dpkg-deb --build --root-owner-group "$package_root" "$output_deb"
dpkg-deb --info "$output_deb"
dpkg-deb --contents "$output_deb" | grep -E \
  'usr/bin/ccs-sleep-studio|usr/lib/ccs-sleep-studio/CCSSleepStudio|usr/lib/ccs-sleep-studio/analyse-nidra|ccs-sleep-studio.desktop'
