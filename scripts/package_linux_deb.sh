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
  "$package_root/usr/share/icons/hicolor/256x256/apps"
cp -a "$bundle_dir/." "$install_dir/"
ln -s ../lib/ccs-sleep-studio/CCSSleepStudio "$package_root/usr/bin/ccs-sleep-studio"
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
Depends: libgtk-3-0, libblkid1, liblzma5, libmpv1 | libmpv2
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
Exec=/usr/bin/ccs-sleep-studio
Icon=ccs-sleep-studio
Terminal=false
Categories=Science;Education;MedicalSoftware;
StartupNotify=true
StartupWMClass=CCSSleepStudio
EOF

mkdir -p "$(dirname "$output_deb")"
dpkg-deb --build --root-owner-group "$package_root" "$output_deb"
dpkg-deb --info "$output_deb"
dpkg-deb --contents "$output_deb" | grep -E \
  'usr/bin/ccs-sleep-studio|usr/lib/ccs-sleep-studio/CCSSleepStudio|usr/lib/ccs-sleep-studio/analyse-nidra|ccs-sleep-studio.desktop'
