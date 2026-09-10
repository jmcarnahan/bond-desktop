#!/usr/bin/env bash
#
# Build the llama-server sidecar that ships inside Bond Desktop.app.
#
# Homebrew's llama-server cannot be bundled: its install names are absolute
# (/opt/homebrew/opt/ggml/…, openssl@3), it is ad-hoc signed by someone else,
# and its ggml backends live under /opt/homebrew/Cellar/ggml/*/libexec. A
# bundled binary has to be relocatable, so we build from source.
#
# The tag and its SHA-256 are LITERALS below, in the style of `make vec-vendor`
# (Makefile:825-844), and for the same reason: there is nothing upstream to
# check a source tarball against, so the digest was measured by hand once at
# pin time and every rebuild is checked against it. A mismatch means the
# tarball changed under the tag — investigate, do not wave it through.
#
# Output is staged, not installed: dist/stage/llama/{bin,lib,backends,metal}.
# dist/bundle.sh copies it into the .app. Re-running is cheap — the .pin stamp
# short-circuits when the staged tree already matches the tag.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Measured 2026-09-10 against
# https://github.com/ggml-org/llama.cpp/archive/refs/tags/b10896.tar.gz
LLAMA_TAG=b10896
LLAMA_SHA256=04539df07b859b1e0dc6f767b1a2d1b0d1d1d568e84d9e2cc9a186089b418395
LLAMA_URL="https://github.com/ggml-org/llama.cpp/archive/refs/tags/${LLAMA_TAG}.tar.gz"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; RESET='\033[0m'
ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
bad()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }
note() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
step() { printf "${BLUE}==>${RESET} %s\n" "$*"; }

STAGE="$ROOT/dist/stage/llama"
PIN="$STAGE/.pin"

# The stamp carries the tag AND a digest of THIS SCRIPT. Editing a cmake flag
# has to invalidate the cache exactly the way bumping the tag does: without
# the digest, a flag change silently reused a tree built with the old flags,
# and the staged sidecar no longer matched the script that claims to build it.
PIN_STAMP="$LLAMA_TAG $(shasum -a 256 "${BASH_SOURCE[0]}" | cut -c1-16)"

if [ -f "$PIN" ] && [ "$(cat "$PIN")" = "$PIN_STAMP" ] && [ -x "$STAGE/bin/llama-server" ]; then
  ok "llama.cpp $LLAMA_TAG already staged in dist/stage/llama (delete .pin to force)"
  exit 0
fi

step "[1/6] prerequisites"
if ! command -v cmake >/dev/null 2>&1; then
  bad "cmake is not installed — run: brew install cmake"
  exit 1
fi
ok "cmake $(cmake --version | head -1 | awk '{print $3}')"
# Xcode 26 ships without the Metal shader compiler. Caught here rather than
# eight minutes into the build, where it surfaces as a pile of .air errors
# that never mention the missing component.
if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  bad "Metal toolchain missing — run: xcodebuild -downloadComponent MetalToolchain"
  exit 1
fi
ok "Metal toolchain"

tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT

step "[2/6] llama.cpp $LLAMA_TAG source"
if ! curl -sfL -o "$tmp/llama.tar.gz" "$LLAMA_URL"; then
  bad "download failed: $LLAMA_URL"
  exit 1
fi
got="$(shasum -a 256 "$tmp/llama.tar.gz" | awk '{print $1}')"
if [ "$got" != "$LLAMA_SHA256" ]; then
  bad "SHA256 mismatch for ${LLAMA_TAG}.tar.gz"
  printf "        want %s\n" "$LLAMA_SHA256"
  printf "        got  %s\n" "$got"
  exit 1
fi
ok "$got"
tar -xzf "$tmp/llama.tar.gz" -C "$tmp"
SRC="$tmp/llama.cpp-$LLAMA_TAG"
[ -d "$SRC" ] || { bad "unexpected archive layout: $SRC is missing"; exit 1; }

# Every flag here is load-bearing:
#   GGML_METAL_EMBED_LIBRARY=OFF  ship real .metallib files; embedded shaders
#                                 JIT-compile on every start and have deadlocked.
#   GGML_BACKEND_DL=ON            backends become dlopen'd .so modules, which is
#                                 what lets them sit beside the executable.
#   GGML_NATIVE=OFF + CPU_ALL_VARIANTS  the binary must run on any Apple Silicon
#                                 Mac, not just the one that built it.
#   LLAMA_CURL=OFF                the app downloads weights; no libcurl to audit.
#   LLAMA_OPENSSL=OFF             the default ON runs find_package(OpenSSL),
#                                 which on any Mac with Homebrew links
#                                 /opt/homebrew/opt/openssl@3 into the binary
#                                 and makes it unbundlable. HTTPS is only for
#                                 -hf downloads and --ssl-key-file; we use
#                                 neither. Step 6 below is what catches a
#                                 regression here.
#   LLAMA_USE_PREBUILT_UI=OFF     the default ON downloads a web-UI tarball
#                                 from Hugging Face DURING the build, which
#                                 makes a SHA-pinned source build depend on a
#                                 mutable remote (and fails outright at this
#                                 tag). The app speaks HTTP to the server and
#                                 never opens the UI.
#   CMAKE_INSTALL_RPATH           @loader_path finds the .so backends in
#                                 Contents/MacOS, ../Frameworks the dylibs.
step "[3/6] configure"
cmake -S "$SRC" -B "$tmp/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=12.0 \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=OFF \
  -DGGML_BACKEND_DL=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_CPU_ALL_VARIANTS=ON \
  -DLLAMA_CURL=OFF \
  -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_UI=OFF \
  -DLLAMA_USE_PREBUILT_UI=OFF \
  -DBUILD_SHARED_LIBS=ON \
  "-DCMAKE_INSTALL_RPATH=@loader_path;@loader_path/../Frameworks" \
  -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON \
  > "$tmp/configure.log" 2>&1 || { bad "cmake configure failed"; tail -40 "$tmp/configure.log"; exit 1; }
ok "configured"

# ggml-metal-lib alongside llama-server: the compiled Metal shaders are
# produced by their own custom target, so building llama-server alone leaves
# default.metallib and ggml-tensor.metallib absent — and a sidecar without
# them JIT-compiles every shader at each start, which is the thing
# GGML_METAL_EMBED_LIBRARY=OFF exists to avoid.
#
# This step needs Xcode's Metal toolchain, which Xcode 26 does not install by
# default: xcodebuild -downloadComponent MetalToolchain. `make dist-check`
# reports it.
step "[4/6] build (this takes a few minutes)"
cmake --build "$tmp/build" --target llama-server ggml-metal-lib -j"$(sysctl -n hw.ncpu)" \
  > "$tmp/build.log" 2>&1 || { bad "build failed"; tail -60 "$tmp/build.log"; exit 1; }
ok "built"

# Deliberately NO `cmake --install`. Two reasons:
#   - LLAMA_BUILD_TOOLS=ON registers an install rule for every tool in the
#     tree, so installing demands binaries we never asked to build (llama-bench,
#     batched-bench, …) and fails on the first one that is missing.
#   - It would buy nothing. CMAKE_BUILD_WITH_INSTALL_RPATH=ON above means the
#     binaries in build/bin ALREADY carry the final @loader_path rpath, and
#     everything staged below is there: the executable, the dylibs with their
#     version symlink chains, the .so backends and the metallibs. The install
#     prefix would add headers and cmake config files we do not ship.
BIN="$tmp/build/bin"

step "[5/6] stage dist/stage/llama"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/backends" "$STAGE/metal"

[ -x "$BIN/llama-server" ] || { bad "llama-server was not produced"; exit 1; }
cp -p "$BIN/llama-server" "$STAGE/bin/llama-server"

# cp -P, and -maxdepth 1 so a nested build artefact cannot shadow the real
# one: the versioned chain (libggml.dylib → libggml.0.dylib →
# libggml.0.23.0.dylib) has to arrive as links, not three full copies.
libs=$(find "$BIN" -maxdepth 1 \
  \( -name 'libllama*.dylib' -o -name 'libmtmd*.dylib' -o -name 'libggml*.dylib' \) \
  2>/dev/null | sort)
[ -n "$libs" ] || { bad "no shared libraries found — is BUILD_SHARED_LIBS really on?"; exit 1; }
while IFS= read -r f; do cp -P "$f" "$STAGE/lib/"; done <<< "$libs"

backends=$(find "$BIN" -maxdepth 1 -name 'libggml-*.so' 2>/dev/null | sort)
[ -n "$backends" ] || { bad "no libggml-*.so backend modules found — is GGML_BACKEND_DL really on?"; exit 1; }
while IFS= read -r f; do cp -P "$f" "$STAGE/backends/"; done <<< "$backends"

metal=$(find "$BIN" -maxdepth 1 -name '*.metallib' 2>/dev/null | sort)
if [ -n "$metal" ]; then
  while IFS= read -r f; do cp -p "$f" "$STAGE/metal/"; done <<< "$metal"
else
  note "no .metallib produced — Metal shaders may be embedded; check GGML_METAL_EMBED_LIBRARY"
fi

step "[6/6] relocatability check"
bad_refs=0
while IFS= read -r f; do
  refs="$(otool -L "$f" 2>/dev/null | tail -n +2 | grep -E '/opt/homebrew|/usr/local' || true)"
  if [ -n "$refs" ]; then
    bad "$(basename "$f") links against a machine-local path:"
    printf "%s\n" "$refs"
    bad_refs=1
  fi
done < <(find "$STAGE/bin" "$STAGE/lib" "$STAGE/backends" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \))
if [ "$bad_refs" -ne 0 ]; then
  bad "the sidecar is not relocatable — it would break on any machine without Homebrew"
  exit 1
fi
ok "no /opt/homebrew or /usr/local install names"

printf "\n"
step "staged tree"
while IFS= read -r f; do
  printf "  %8s  %s\n" "$(du -h "$f" | cut -f1)" "${f#"$STAGE"/}"
done < <(find "$STAGE" -type f -o -type l | sort)

# Last, so an interrupted run does not look cached on the next one.
printf '%s\n' "$PIN_STAMP" > "$PIN"
printf "\n"
ok "llama.cpp $LLAMA_TAG staged in dist/stage/llama"
