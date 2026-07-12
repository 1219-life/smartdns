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
    MUSL_LOADER='ld-musl-x86_64.so.1'
    ;;
  arm64)
    BUILD_ARCH="arm64"
    CROSS_ARGS=(--cross-tool aarch64-linux-gnu-)
    EXPECTED_MACHINE='AArch64'
    MUSL_LOADER='ld-musl-aarch64.so.1'
    ;;
  *) usage ;;
esac

case "$VARIANT" in
  dynamic-ui)
    [[ -n "${MUSL_CROSS_PREFIX:-}" ]] || {
      echo "MUSL_CROSS_PREFIX is required for dynamic-ui builds" >&2
      exit 1
    }
    CROSS_ARGS=(--cross-tool "$MUSL_CROSS_PREFIX")
    BUILD_ARGS=(--static --with-ui)
    ;;
  static)
    BUILD_ARGS=(--static)
    ;;
  *) usage ;;
esac

PACKAGE_NAME="smartdns-${RELEASE_TAG}-linux-${ARCH}-${VARIANT}"
BUILD_OUTPUT="$(mktemp -d)"
PACKAGE_ROOT="$(mktemp -d)"
TEMP_LOADER_LINK=""
TEMP_SSL_LINK=""
TEMP_CRYPTO_LINK=""
cleanup() {
  rm -rf "$BUILD_OUTPUT" "$PACKAGE_ROOT"
  [[ -z "$TEMP_LOADER_LINK" ]] || rm -f "$TEMP_LOADER_LINK"
  [[ -z "$TEMP_SSL_LINK" ]] || rm -f "$TEMP_SSL_LINK"
  [[ -z "$TEMP_CRYPTO_LINK" ]] || rm -f "$TEMP_CRYPTO_LINK"
}
trap cleanup EXIT

if [[ "$VARIANT" == "dynamic-ui" ]]; then
  MUSL_LIBC="$("${MUSL_CROSS_PREFIX}gcc" -print-file-name=libc.so)"
  [[ -f "$MUSL_LIBC" ]] || { echo "musl libc was not found in the toolchain" >&2; exit 1; }
  TEMP_LOADER_LINK="$SOURCE_DIR/$MUSL_LOADER"
  ln -s "$MUSL_LIBC" "$TEMP_LOADER_LINK"
  MUSL_SYSROOT="$("${MUSL_CROSS_PREFIX}gcc" --print-sysroot)"
  OPENSSL_LIB_DIR="$(find "$MUSL_SYSROOT" -type f -name libssl.so.3 -exec dirname {} \; -quit)"
  [[ -n "$OPENSSL_LIB_DIR" ]] || { echo "shared OpenSSL libraries were not found in the toolchain sysroot" >&2; exit 1; }
  export LDFLAGS="-L$OPENSSL_LIB_DIR ${LDFLAGS:-}"
  TEMP_SSL_LINK="$SOURCE_DIR/libssl.so.3"
  TEMP_CRYPTO_LINK="$SOURCE_DIR/libcrypto.so.3"
  ln -s "$OPENSSL_LIB_DIR/libssl.so.3" "$TEMP_SSL_LINK"
  ln -s "$OPENSSL_LIB_DIR/libcrypto.so.3" "$TEMP_CRYPTO_LINK"
fi

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
[[ -e "$SMARTDNS_BIN" || -L "$SMARTDNS_BIN" ]] || {
  echo "Missing usr/sbin/smartdns" >&2
  exit 1
}

if [[ "$VARIANT" == "dynamic-ui" ]]; then
  BUNDLED_ROOT="$ROOT_DIR/usr/local/lib/smartdns"
  [[ -L "$SMARTDNS_BIN" ]] || { echo "usr/sbin/smartdns is not the bundled launcher symlink" >&2; exit 1; }
  [[ "$(readlink "$SMARTDNS_BIN")" == "/usr/local/lib/smartdns/run-smartdns" ]] || {
    echo "usr/sbin/smartdns does not point to the bundled launcher" >&2
    exit 1
  }
  SMARTDNS_ELF="$BUNDLED_ROOT/smartdns"
else
  [[ -x "$SMARTDNS_BIN" ]] || { echo "usr/sbin/smartdns is not executable" >&2; exit 1; }
  SMARTDNS_ELF="$SMARTDNS_BIN"
fi

machine="$(readelf -h "$SMARTDNS_ELF" | sed -n 's/^[[:space:]]*Machine:[[:space:]]*//p')"
[[ "$machine" == *"$EXPECTED_MACHINE"* ]] || {
  echo "Unexpected binary architecture: $machine" >&2
  exit 1
}

if [[ "$VARIANT" == "dynamic-ui" ]]; then
  UI_PLUGIN="$BUNDLED_ROOT/smartdns_ui.so"
  BUNDLED_LIB="$BUNDLED_ROOT/lib"
  WWW_ROOT="$ROOT_DIR/usr/share/smartdns/wwwroot"

  if [[ ! -e "$BUNDLED_LIB/$MUSL_LOADER" && ! -L "$BUNDLED_LIB/$MUSL_LOADER" ]]; then
    ln -s libc.so "$BUNDLED_LIB/$MUSL_LOADER"
  fi

  [[ -x "$BUNDLED_ROOT/run-smartdns" ]] || { echo "Missing bundled run-smartdns" >&2; exit 1; }
  [[ -x "$SMARTDNS_ELF" ]] || { echo "Missing bundled smartdns executable" >&2; exit 1; }
  [[ -f "$UI_PLUGIN" ]] || { echo "Missing smartdns_ui.so" >&2; exit 1; }
  [[ -L "$BUNDLED_LIB/ld-linux.so" ]] || { echo "Missing bundled ld-linux.so symlink" >&2; exit 1; }
  compgen -G "$BUNDLED_LIB/ld-musl-*.so.1" >/dev/null || { echo "Missing bundled musl loader" >&2; exit 1; }
  [[ -f "$BUNDLED_LIB/libc.so" ]] || { echo "Missing bundled libc.so" >&2; exit 1; }
  [[ -f "$BUNDLED_LIB/libcrypto.so.3" ]] || { echo "Missing bundled libcrypto.so.3" >&2; exit 1; }
  [[ -f "$BUNDLED_LIB/libssl.so.3" ]] || { echo "Missing bundled libssl.so.3" >&2; exit 1; }
  [[ -f "$BUNDLED_LIB/libgcc_s.so.1" ]] || { echo "Missing bundled libgcc_s.so.1" >&2; exit 1; }
  [[ -f "$WWW_ROOT/index.html" ]] || { echo "Missing wwwroot/index.html" >&2; exit 1; }
  [[ -f "$ROOT_DIR/etc/smartdns/smartdns.conf" ]] || { echo "Missing example configuration" >&2; exit 1; }
  [[ -f "$ROOT_DIR/systemd/smartdns.service" ]] || { echo "Missing systemd service" >&2; exit 1; }
  readelf -l "$SMARTDNS_ELF" | grep -q 'INTERP' || {
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
