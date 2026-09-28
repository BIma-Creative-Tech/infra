#!/bin/bash
# Bootstrap Android SDK di cache persisten (/cache/android-sdk) — plan 12 R6. Jalan sebagai uid 1001 (role ci_runner,
# container sekali pakai, network ci-runner). Semua unduhan diverifikasi sha256. Idempoten (marker per daftar paket).
set -euo pipefail
: "${CMDLINE_TOOLS_REV:?}" "${CMDLINE_TOOLS_SHA256:?}" "${JRE_URL:?}" "${JRE_SHA256:?}" "${ANDROID_PACKAGES:?}"
SDK="${ANDROID_HOME:-/cache/android-sdk}"
JRE_DIR=/cache/toolcache/bootstrap-jre
MARKER="$SDK/.ci-runner-bootstrap"
WANT="$(printf '%s|%s|%s' "$CMDLINE_TOOLS_REV" "$JRE_SHA256" "$ANDROID_PACKAGES" | sha256sum | cut -d' ' -f1)"
if [[ -f "$MARKER" && "$(cat "$MARKER")" == "$WANT" ]]; then echo "android-bootstrap: up to date"; exit 0; fi
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$SDK" "$JRE_DIR"

if [[ ! -x "$JRE_DIR/bin/java" ]]; then
  curl -fsSL -o "$tmp/jre.tgz" "$JRE_URL"
  echo "$JRE_SHA256  $tmp/jre.tgz" | sha256sum -c -
  tar -xzf "$tmp/jre.tgz" -C "$JRE_DIR" --strip-components=1
fi
export JAVA_HOME="$JRE_DIR" PATH="$JRE_DIR/bin:$PATH"

if [[ "$(cat "$SDK/cmdline-tools/latest/.rev" 2>/dev/null)" != "$CMDLINE_TOOLS_REV" ]]; then
  curl -fsSL -o "$tmp/clt.zip" "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS_REV}_latest.zip"
  echo "$CMDLINE_TOOLS_SHA256  $tmp/clt.zip" | sha256sum -c -
  rm -rf "$SDK/cmdline-tools/latest"; mkdir -p "$SDK/cmdline-tools"
  unzip -q "$tmp/clt.zip" -d "$tmp/clt"
  mv "$tmp/clt/cmdline-tools" "$SDK/cmdline-tools/latest"
  echo "$CMDLINE_TOOLS_REV" > "$SDK/cmdline-tools/latest/.rev"
fi
SDKM="$SDK/cmdline-tools/latest/bin/sdkmanager"
# Lisensi SDK Android (syarat build Gradle/AGP; setara GitHub-hosted image yang sudah menerima lisensi).
yes | "$SDKM" --sdk_root="$SDK" --licenses >/dev/null
IFS=',' read -r -a pkgs <<<"$ANDROID_PACKAGES"
"$SDKM" --sdk_root="$SDK" --install "${pkgs[@]}" | grep -v '^\[' || true
"$SDKM" --sdk_root="$SDK" --list_installed
echo "$WANT" > "$MARKER"
echo "android-bootstrap: done"
