#!/usr/bin/env bash
set -euo pipefail

export PATH="/opt/flutter/bin:/root/.cargo/bin:$PATH"
git config --global --add safe.directory '*'

echo "=== System GLIBC version ==="
ldd --version | head -n 1

echo "=== Building Rust backend (librust_sleep_eeg.so) ==="
(cd bridge && cargo build --release)

echo "=== Building AnalyseNidra CLI (analyse-nidra) ==="
(cd analyseNidra && cargo build --release)

echo "=== Flutter dependencies & analysis ==="
(cd frontend && flutter pub get && flutter analyze && flutter test)

echo "=== Building Linux app (Lite) ==="
(cd frontend && flutter build linux --release --dart-define=LITE_BUILD=true)

cp bridge/target/release/librust_sleep_eeg.so frontend/build/linux/x64/release/bundle/
cp analyseNidra/target/release/analyse-nidra frontend/build/linux/x64/release/bundle/
test -x frontend/build/linux/x64/release/bundle/analyse-nidra

mkdir -p dist
bash scripts/package_linux_deb.sh \
  frontend/build/linux/x64/release/bundle \
  dist/CCSSleepStudio-lite-linux-amd64.deb \
  lite
bash scripts/package_linux_rpm.sh \
  frontend/build/linux/x64/release/bundle \
  dist/CCSSleepStudio-lite-linux-x86_64.rpm \
  lite

echo "=== Building Linux app (Full) ==="
(cd frontend && flutter build linux --release)

cp bridge/target/release/librust_sleep_eeg.so frontend/build/linux/x64/release/bundle/
cp analyseNidra/target/release/analyse-nidra frontend/build/linux/x64/release/bundle/
mkdir -p frontend/build/linux/x64/release/bundle/assets
cp -r analyseNidra/assets/models frontend/build/linux/x64/release/bundle/assets/
test -x frontend/build/linux/x64/release/bundle/analyse-nidra

bash scripts/package_linux_deb.sh \
  frontend/build/linux/x64/release/bundle \
  dist/CCSSleepStudio-linux-amd64.deb \
  full
bash scripts/package_linux_rpm.sh \
  frontend/build/linux/x64/release/bundle \
  dist/CCSSleepStudio-linux-x86_64.rpm \
  full

echo "=== Verifying GLIBC requirements in output binaries ==="
for binary in frontend/build/linux/x64/release/bundle/CCSSleepStudio \
              frontend/build/linux/x64/release/bundle/analyse-nidra \
              frontend/build/linux/x64/release/bundle/librust_sleep_eeg.so; do
  echo "Checking $binary..."
  objdump -p "$binary" | grep -E "GLIBC_2\.(29|[3-9][0-9])" && {
    echo "ERROR: $binary requires GLIBC > 2.28!"
    exit 1
  } || echo "$binary is GLIBC 2.28 compatible."
done

echo "=== Linux build and packaging completed successfully ==="
