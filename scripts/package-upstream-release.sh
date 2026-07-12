#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <source-dir> <output-dir> <release-tag> <amd64|arm64> <dynamic-ui|static>" >&2
  exit 2
}

[[ $# -eq 5 ]] || usage

SOURCE_DIR="$(realpath "$1")"
OUTPUT_DIR="$(mkdir -p "$2" && realpath "$2")"
RELEASE_TAG="$3"
ARCH="$4"
VARIANT="$5"

case "$ARCH" in
  amd64)
    BUILD_ARCH="x86-64"
    CROSS_ARGS=()
    EXPECTED_MACHINE='Advanced Micro Devices X86-64'
    ;;
  arm64)
    BUILD_ARCH="arm64"
    CROSS_ARGS=(--cross-tool aarch64-linux-gnu-)
    EXPECTED_MACHINE='AArch64'
    ;;
  *) usage ;;
esac

case "$VARIANT" in
  dynamic-ui)
    BUILD_ARGS=(--with-ui)
    ;;
  static)
    BUILD_ARGS=(--static)
    ;;
  *) usage ;;
esac

PACKAGE_NAME="smartdns-${RELEASE_TAG}-linux-${ARCH}-${VARIANT}"
BUILD_OUTPUT="$(mktemp -d)"
PACKAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "$BUILD_OUTPUT" "$PACKAGE_ROOT"' EXIT

echo "Building ${PACKAGE_NAME} with the upstream package script"
(
  cd "$SOURCE_DIR"
  package/build-pkg.sh \
    --platform linux \
    --arch "$BUILD_ARCH" \
    --filearch "$PACKAGE_NAME" \
    --ver "$RELEASE_TAG" \
    --outputdir "$BUILD_OUTPUT" \
    "${CROSS_ARGS[@]}" \
    "${BUILD_ARGS[@]}"
)

mapfile -t upstream_archives < <(find "$BUILD_OUTPUT" -maxdepth 1 -type f -name '*.tar.gz' -print)
[[ ${#upstream_archives[@]} -eq 1 ]] || {
  echo "Expected exactly one upstream archive; found ${#upstream_archives[@]}" >&2
  exit 1
}

tar -xzf "${upstream_archives[0]}" -C "$PACKAGE_ROOT"
ROOT_DIR="$PACKAGE_ROOT/smartdns"
[[ -d "$ROOT_DIR" ]] || {
  echo "The upstream Linux archive did not contain the expected smartdns root" >&2
  exit 1
}

SMARTDNS_BIN="$ROOT_DIR/usr/sbin/smartdns"
[[ -x "$SMARTDNS_BIN" ]] || {
  echo "Missing executable usr/sbin/smartdns" >&2
  exit 1
}

machine="$(readelf -h "$SMARTDNS_BIN" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
[[ "$machine" == *"$EXPECTED_MACHINE"* ]] || {
  echo "Unexpected binary architecture: $machine" >&2
  exit 1
}

if [[ "$VARIANT" == "dynamic-ui" ]]; then
  UI_PLUGIN="$ROOT_DIR/usr/local/lib/smartdns/smartdns_ui.so"
  WWW_ROOT="$ROOT_DIR/usr/share/smartdns/wwwroot"

  [[ -f "$UI_PLUGIN" ]] || { echo "Missing smartdns_ui.so" >&2; exit 1; }
  [[ -f "$WWW_ROOT/index.html" ]] || { echo "Missing wwwroot/index.html" >&2; exit 1; }
  [[ -f "$ROOT_DIR/etc/smartdns/smartdns.conf" ]] || { echo "Missing example configuration" >&2; exit 1; }
  [[ -f "$ROOT_DIR/systemd/smartdns.service" ]] || { echo "Missing systemd service" >&2; exit 1; }
  readelf -l "$SMARTDNS_BIN" | grep -q 'INTERP' || {
    echo "Dynamic package binary has no ELF interpreter" >&2
    exit 1
  }
  readelf -d "$UI_PLUGIN" | grep -q '(NEEDED)' || {
    echo "UI plugin has no dynamic dependencies" >&2
    exit 1
  }
else
  if readelf -l "$SMARTDNS_BIN" | grep -q 'INTERP'; then
    echo "Static package unexpectedly contains an ELF interpreter" >&2
    exit 1
  fi
  if readelf -d "$SMARTDNS_BIN" 2>/dev/null | grep -q '(NEEDED)'; then
    echo "Static package unexpectedly contains dynamic dependencies" >&2
    exit 1
  fi
  file "$SMARTDNS_BIN" | grep -q 'statically linked' || {
    echo "file(1) did not identify the binary as statically linked" >&2
    exit 1
  }
fi

SOURCE_SHA="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
BUILT_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
cat > "$ROOT_DIR/manifest.json" <<EOF
{
  "name": "smartdns",
  "upstream_repository": "pymumu/smartdns",
  "upstream_tag": "${RELEASE_TAG}",
  "upstream_commit": "${SOURCE_SHA}",
  "platform": "linux",
  "architecture": "${ARCH}",
  "variant": "${VARIANT}",
  "built_at": "${BUILT_AT}",
  "builder_repository": "${GITHUB_REPOSITORY:-local}",
  "builder_run_id": "${GITHUB_RUN_ID:-local}"
}
EOF

mv "$ROOT_DIR" "$PACKAGE_ROOT/$PACKAGE_NAME"
tar --sort=name --owner=0 --group=0 --numeric-owner \
  -czf "$OUTPUT_DIR/$PACKAGE_NAME.tar.gz" \
  -C "$PACKAGE_ROOT" "$PACKAGE_NAME"

(
  cd "$OUTPUT_DIR"
  sha256sum "$PACKAGE_NAME.tar.gz" > "$PACKAGE_NAME.sha256"
)

echo "Created $OUTPUT_DIR/$PACKAGE_NAME.tar.gz"
