#!/usr/bin/env bash
#
# Build the cross-assembler (vasm, m68k/Motorola-DEVPAC syntax) and linker (vlink)
# from source into ./.tools/bin. These are tiny, portable C programs; building from
# source avoids vasm's binary-redistribution licensing and keeps the environment lean.
#
# Idempotent: skips work if the binaries already exist. Run again with `--force` to rebuild.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
BIN="$TOOLS/bin"
SRC="$TOOLS/src"

VASM_URL="http://sun.hasenbraten.de/vasm/release/vasm.tar.gz"
VLINK_URL="http://sun.hasenbraten.de/vlink/release/vlink.tar.gz"

FORCE="${1:-}"
mkdir -p "$BIN" "$SRC"

have() { [ -x "$BIN/$1" ] && [ "$FORCE" != "--force" ]; }

build_vasm() {
    if have vasmm68k_mot; then echo "vasm: already built"; return; fi
    echo "vasm: fetching + building (m68k / mot syntax)..."
    rm -rf "$SRC/vasm"
    curl -fsSL "$VASM_URL" | tar -xz -C "$SRC"
    make -C "$SRC/vasm" CPU=m68k SYNTAX=mot >/dev/null
    cp "$SRC/vasm/vasmm68k_mot" "$BIN/"
    cp "$SRC/vasm/vobjdump"     "$BIN/" 2>/dev/null || true
    echo "vasm: built -> $BIN/vasmm68k_mot"
}

build_vlink() {
    if have vlink; then echo "vlink: already built"; return; fi
    echo "vlink: fetching + building..."
    rm -rf "$SRC/vlink"
    # vlink tarball extracts into a versioned dir; normalise to $SRC/vlink
    tmp="$(mktemp -d)"
    curl -fsSL "$VLINK_URL" | tar -xz -C "$tmp"
    mv "$tmp"/vlink* "$SRC/vlink"
    rmdir "$tmp"
    make -C "$SRC/vlink" >/dev/null
    cp "$SRC/vlink/vlink" "$BIN/"
    echo "vlink: built -> $BIN/vlink"
}

build_vasm
build_vlink

echo
echo "Tools ready in $BIN:"
ls -1 "$BIN"
echo
echo 'Add to PATH:  export PATH="'"$BIN"':$PATH"   (devbox init_hook does this automatically)'
