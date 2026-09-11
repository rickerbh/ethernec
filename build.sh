#!/usr/bin/env bash
#
# Cross-build EtherNEC test programs / driver on Linux using vasm (+ vlink).
#
# Usage:  ./build.sh <target> [bus-variant]
#   target       one of: ht1 ht2 ht3 ht4   (pure-asm hardware tests, no C, no stack)
#   bus-variant  BUSENEC.I (68000 cartridge) | BUSENEC3.I (68020+/TT cartridge, default)
#                also: BUSENEAF.I BUSENEAS.I (ACSI), BUSENEM.I (Milan), BUSENEH.I (Hades)
#
# The chosen bus variant is staged as BUS.I in build/, mirroring the original Makefile
# (which copies BUSENE*.I over BUS.I). Sources are symlinked so SRC/ stays pristine.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/SRC"
BUILD="$ROOT/build"
export PATH="$ROOT/.tools/bin:$PATH"

TARGET="${1:-ht2}"
BUS_VARIANT="${2:-BUSENEC3.I}"

# CPU flag: the *3 cartridge variant and Hades need 68020+; the TT is 68030.
case "$BUS_VARIANT" in
  BUSENEC3.I|BUSENEH.I) CPU="-m68030" ;;
  *)                    CPU="-m68000" ;;
esac

# --- stage sources -----------------------------------------------------------
mkdir -p "$BUILD"
find "$BUILD" -maxdepth 1 -type l -delete
for f in "$SRC"/*.I "$SRC"/*.S "$SRC"/*.H; do
    ln -sf "$f" "$BUILD/$(basename "$f")"
done
rm -f "$BUILD/BUS.I"                 # remove the symlink to SRC/BUS.I (Hades)
cp "$SRC/$BUS_VARIANT" "$BUILD/BUS.I"  # real copy of the chosen variant wins
echo "bus variant: $BUS_VARIANT   cpu: $CPU"

VASM="vasmm68k_mot $CPU -Ftos -devpac -quiet -I $BUILD ${RECOVER:+-DNE_RECOVER=$RECOVER}"
[ -n "${RECOVER:-}" ] && echo "recovery pad: NE_RECOVER=$RECOVER nops/access"

# --- targets -----------------------------------------------------------------
case "$TARGET" in
  ht1) SRCFILE=HT1ENE.S  ; OUT=HT1ENEC.TOS ;;
  ht2) SRCFILE=HT2ENE.S  ; OUT=HT2ENEC.TOS ;;
  ht3) SRCFILE=HT3ENE.S  ; OUT=HT3ENEC.TOS ;;
  ht4) SRCFILE=HT4ENEC.S ; OUT=HT4ENEC.TOS ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

echo "assembling $SRCFILE -> build/$OUT"
$VASM "$BUILD/$SRCFILE" -L "$BUILD/${OUT%.TOS}.lst" -o "$BUILD/$OUT"
echo
ls -l "$BUILD/$OUT"
file "$BUILD/$OUT"
