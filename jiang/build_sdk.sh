#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLVM_VERSION="22.1.8"
LLVM_REVISION="ca7933e47d3a3451d81e72ac174dcb5aa28b59d1"
LLVM_PROJECTS="clang;lld"
LLVM_TARGETS="X86;AArch64;WebAssembly"
MACOS_DEPLOYMENT_TARGET="11.0"

PACKAGE_REVISION=""
OUTPUT_DIR="$ROOT_DIR/build/jiang-sdk"
BUILD_DIR="$ROOT_DIR/build/jiang-sdk/llvm-build"
PARALLEL=""
ALLOW_DIRTY=0

usage() {
  cat <<'EOF'
usage: bash ./jiang/build_sdk.sh --package-revision <number> [options]

Build and package the LLVM toolchain used by Jiang.

options:
  --package-revision <number>  Jiang packaging revision, for example 1
  --output-dir <path>          archive output directory
  --build-dir <path>           CMake build directory
  --parallel <number>          maximum parallel build jobs
  --allow-dirty                allow a dirty source tree for local testing
  -h, --help                   show this help
EOF
}

fail() {
  echo "$*" >&2
  exit 2
}

require_value() {
  if [ "$#" -lt 2 ] || [ -z "$2" ]; then
    fail "missing value for $1"
  fi
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --package-revision)
        require_value "$@"
        PACKAGE_REVISION="$2"
        shift 2
        ;;
      --output-dir)
        require_value "$@"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --build-dir)
        require_value "$@"
        BUILD_DIR="$2"
        shift 2
        ;;
      --parallel)
        require_value "$@"
        PARALLEL="$2"
        shift 2
        ;;
      --allow-dirty)
        ALLOW_DIRTY=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown option: $1"
        ;;
    esac
  done
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "missing required command: $1"
  fi
}

host_tag() {
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64|Darwin:aarch64)
      printf '%s\n' "macos-arm64"
      ;;
    Linux:x86_64|Linux:amd64)
      printf '%s\n' "linux-x86_64"
      ;;
    *)
      fail "unsupported SDK host: $(uname -s) $(uname -m)"
      ;;
  esac
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return
  fi
  shasum -a 256 "$1" | awk '{print $1}'
}

check_source() {
  local dirty
  local described_version
  local changed_path
  described_version="$(sed -n \
    's/^[[:space:]]*set(LLVM_VERSION_MAJOR[[:space:]]\([0-9][0-9]*\)).*/\1/p' \
    cmake/Modules/LLVMVersion.cmake)."
  described_version+="$(sed -n \
    's/^[[:space:]]*set(LLVM_VERSION_MINOR[[:space:]]\([0-9][0-9]*\)).*/\1/p' \
    cmake/Modules/LLVMVersion.cmake)."
  described_version+="$(sed -n \
    's/^[[:space:]]*set(LLVM_VERSION_PATCH[[:space:]]\([0-9][0-9]*\)).*/\1/p' \
    cmake/Modules/LLVMVersion.cmake)"
  if [ "$described_version" != "$LLVM_VERSION" ]; then
    fail "expected LLVM $LLVM_VERSION source, got $described_version"
  fi

  if ! git cat-file -e "$LLVM_REVISION^{commit}" 2>/dev/null; then
    fail "missing LLVM revision $LLVM_REVISION; fetch tag llvmorg-$LLVM_VERSION"
  fi
  while IFS= read -r changed_path; do
    case "$changed_path" in
      jiang/*|.github/workflows/jiang-sdk-*.yml) ;;
      *) fail "unexpected change after LLVM revision $LLVM_REVISION: $changed_path" ;;
    esac
  done < <(git diff --name-only "$LLVM_REVISION" HEAD)

  dirty="$(git status --porcelain)"
  if [ -n "$dirty" ] && [ "$ALLOW_DIRTY" != "1" ]; then
    fail "refusing to package a dirty LLVM source tree"
  fi
}

configure_sdk() {
  local install_dir="$1"
  local compiler_args=()
  local platform_args=()

  compiler_args+=("-DCMAKE_C_COMPILER=$(command -v clang)")
  compiler_args+=("-DCMAKE_CXX_COMPILER=$(command -v clang++)")
  if [ "$(uname -s)" = "Darwin" ]; then
    platform_args+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_DEPLOYMENT_TARGET")
    export MACOSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET"
  fi

  cmake -G Ninja -S llvm -B "$BUILD_DIR" \
    "${compiler_args[@]}" \
    "${platform_args[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DLLVM_ENABLE_PROJECTS="$LLVM_PROJECTS" \
    -DLLVM_TARGETS_TO_BUILD="$LLVM_TARGETS" \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DLLVM_BUILD_LLVM_DYLIB=OFF \
    -DLLVM_LINK_LLVM_DYLIB=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_TESTS=OFF
}

build_sdk() {
  local build_args=(--build "$BUILD_DIR" --target install)
  if [ -n "$PARALLEL" ]; then
    build_args+=(--parallel "$PARALLEL")
  fi
  cmake "${build_args[@]}"
}

write_manifest() {
  local sdk_root="$1"
  local sdk_version="$2"
  local source_revision="$3"
  local host="$4"
  local manifest_dir="$sdk_root/share/jiang"
  local platform_metadata
  case "$host" in
    macos-arm64)
      platform_metadata="  \"macos_deployment_target\": \"$MACOS_DEPLOYMENT_TARGET\""
      ;;
    linux-x86_64)
      platform_metadata="  \"linux_build_libc\": \"$(getconf GNU_LIBC_VERSION)\""
      ;;
  esac
  mkdir -p "$manifest_dir" "$sdk_root/share/licenses/jiang-llvm"
  cp LICENSE.TXT "$sdk_root/share/licenses/jiang-llvm/LLVM-LICENSE.txt"
  cat >"$manifest_dir/llvm-sdk.json" <<EOF
{
  "schema": 1,
  "sdk_version": "$sdk_version",
  "llvm_version": "$LLVM_VERSION",
  "llvm_revision": "$LLVM_REVISION",
  "sdk_revision": "$source_revision",
  "host": "$host",
  "projects": ["clang", "lld"],
  "targets": ["X86", "AArch64", "WebAssembly"],
  "build_type": "Release",
  "static_llvm": true,
$platform_metadata
}
EOF
}

verify_sdk() {
  local sdk_root="$1"
  local actual_version
  actual_version="$("$sdk_root/bin/llvm-config" --version)"
  if [ "$actual_version" != "$LLVM_VERSION" ]; then
    fail "expected packaged LLVM $LLVM_VERSION, got $actual_version"
  fi
  "$sdk_root/bin/clang" --version >/dev/null
  "$sdk_root/bin/ld.lld" --version >/dev/null
  "$sdk_root/bin/llvm-config" --link-static --libs all >/dev/null
}

package_sdk() {
  local install_dir="$1"
  local sdk_version="$2"
  local host="$3"
  local package_root="$BUILD_DIR/package"
  local archive_name="jiang-llvm-$sdk_version-$host"
  local sdk_root="$package_root/$archive_name"
  local archive="$OUTPUT_DIR/$archive_name.tar.gz"
  local digest

  rm -rf "$package_root"
  mkdir -p "$sdk_root" "$OUTPUT_DIR"
  cp -a "$install_dir/." "$sdk_root/"
  write_manifest "$sdk_root" "$sdk_version" "$(git rev-parse HEAD)" "$host"
  verify_sdk "$sdk_root"

  COPYFILE_DISABLE=1 tar -C "$package_root" -cf - "$archive_name" | gzip -n -6 >"$archive"
  digest="$(sha256_file "$archive")"
  printf '%s  %s\n' "$digest" "$(basename "$archive")" >"$archive.sha256"
  cp "$sdk_root/share/jiang/llvm-sdk.json" "$archive.manifest.json"
  printf '%s\n' "$archive"
}

main() {
  local install_dir
  local sdk_version
  local host

  parse_args "$@"
  case "$PACKAGE_REVISION" in
    ''|*[!0-9]*|0)
      fail "--package-revision must be a positive integer"
      ;;
  esac
  case "$PARALLEL" in
    '') ;;
    *[!0-9]*|0) fail "--parallel must be a positive integer" ;;
  esac

  require_command awk
  require_command clang
  require_command clang++
  require_command cmake
  require_command getconf
  require_command git
  require_command gzip
  require_command ninja
  require_command sed
  require_command tar

  cd "$ROOT_DIR"
  check_source
  host="$(host_tag)"
  sdk_version="$LLVM_VERSION-$PACKAGE_REVISION"
  install_dir="$BUILD_DIR/install"
  cmake -E remove_directory "$install_dir"
  configure_sdk "$install_dir"
  build_sdk
  package_sdk "$install_dir" "$sdk_version" "$host"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
