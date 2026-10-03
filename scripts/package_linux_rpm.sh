#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <flutter-bundle> <output.rpm> <full|lite>" >&2
  exit 2
fi

bundle_dir=$1
output_rpm=$2
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
top_dir="$work_dir/rpmbuild"
source_dir="$top_dir/SOURCES"
mkdir -p "$source_dir/bundle" "$top_dir/SPECS"
cp -a "$bundle_dir/." "$source_dir/bundle/"
install -m 0644 "$repo_root/frontend/assets/logo.png" \
  "$source_dir/ccs-sleep-studio.png"

cat > "$source_dir/ccs-sleep-studio.desktop" <<EOF
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

cat > "$top_dir/SPECS/ccs-sleep-studio.spec" <<EOF
%global debug_package %{nil}
Name:           $package_name
Version:        $version
Release:        1%{?dist}
Summary:        $description
License:        Proprietary
URL:            https://github.com/arunsasidharan84/CCS-Sleep-Studio
BuildArch:      x86_64
Requires:       gtk3, glibc, libstdc++, xz-libs
Recommends:     mpv-libs
Conflicts:      $conflicts
AutoReqProv:    no

%description
CCS Sleep Studio is a desktop application for polysomnography review,
sleep staging, and advanced quantitative EEG analysis.

%prep

%build

%install
mkdir -p \
  %{buildroot}/usr/lib/ccs-sleep-studio \
  %{buildroot}/usr/bin \
  %{buildroot}/usr/share/applications \
  %{buildroot}/usr/share/pixmaps \
  %{buildroot}/usr/share/icons/hicolor/256x256/apps
cp -a %{_sourcedir}/bundle/. %{buildroot}/usr/lib/ccs-sleep-studio/
ln -s ../lib/ccs-sleep-studio/CCSSleepStudio %{buildroot}/usr/bin/ccs-sleep-studio
install -m 0644 %{_sourcedir}/ccs-sleep-studio.desktop \
  %{buildroot}/usr/share/applications/ccs-sleep-studio.desktop
install -m 0644 %{_sourcedir}/ccs-sleep-studio.png \
  %{buildroot}/usr/share/pixmaps/ccs-sleep-studio.png
install -m 0644 %{_sourcedir}/ccs-sleep-studio.png \
  %{buildroot}/usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png

%post
# 1. libmpv compatibility symlink
for dir in /usr/lib64 /usr/lib; do
  if [ ! -e "\$dir/libmpv.so.1" ] && [ -e "\$dir/libmpv.so.2" ]; then
    ln -sf libmpv.so.2 "\$dir/libmpv.so.1" || true
  fi
done

# 2. Update desktop database and icon caches
if which update-desktop-database >/dev/null 2>&1; then
  update-desktop-database /usr/share/applications 2>/dev/null || true
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
if [ -f "\$launcher" ]; then
  while IFS=: read -r _ _ uid gid _ homedir _; do
    if [ "\$uid" -ge 1000 ] 2>/dev/null && [ -d "\$homedir/Desktop" ]; then
      cp -f "\$launcher" "\$homedir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chmod 755 "\$homedir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chown "\$uid:\$gid" "\$homedir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
    fi
  done < <(getent passwd 2>/dev/null || cat /etc/passwd)

  for udir in /home/* /serverdata/ccshome/* /export/home/* /data/home/*; do
    if [ -d "\$udir/Desktop" ]; then
      cp -f "\$launcher" "\$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      chmod 755 "\$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      owner_id=\$(stat -c '%u:%g' "\$udir" 2>/dev/null || true)
      if [ -n "\$owner_id" ]; then
        chown "\$owner_id" "\$udir/Desktop/ccs-sleep-studio.desktop" 2>/dev/null || true
      fi
    fi
  done
fi

%postun
if [ "\$1" -eq 0 ]; then
  for dir in /usr/lib64 /usr/lib; do
    if [ -L "\$dir/libmpv.so.1" ] && [ "\$(readlink "\$dir/libmpv.so.1")" = "libmpv.so.2" ]; then
      rm -f "\$dir/libmpv.so.1" || true
    fi
  done
  rm -f /etc/skel/Desktop/ccs-sleep-studio.desktop
  if which update-desktop-database >/dev/null 2>&1; then
    update-desktop-database /usr/share/applications 2>/dev/null || true
  fi
  if which gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
  fi
fi

%files
/usr/bin/ccs-sleep-studio
/usr/lib/ccs-sleep-studio
/usr/share/applications/ccs-sleep-studio.desktop
/usr/share/pixmaps/ccs-sleep-studio.png
/usr/share/icons/hicolor/256x256/apps/ccs-sleep-studio.png

%changelog
* Sat Jun 20 2026 CCS Sleep Studio Project <noreply@github.com> - $version-1
- Automated desktop release
EOF

rpmbuild --define "_topdir $top_dir" --target x86_64 \
  -bb "$top_dir/SPECS/ccs-sleep-studio.spec"
built_rpm=$(find "$top_dir/RPMS" -type f -name '*.rpm' -print -quit)
if [[ -z "$built_rpm" ]]; then
  echo "rpmbuild did not produce an RPM package." >&2
  exit 1
fi
mkdir -p "$(dirname "$output_rpm")"
cp "$built_rpm" "$output_rpm"
rpm -qip "$output_rpm"
rpm -qlp "$output_rpm" | grep -E \
  '/usr/bin/ccs-sleep-studio|/usr/lib/ccs-sleep-studio/CCSSleepStudio|/usr/lib/ccs-sleep-studio/analyse-nidra|ccs-sleep-studio.desktop'
