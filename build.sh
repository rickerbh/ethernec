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
# Sources are COPIED (never symlinked -- a cp onto a symlink follows it and
# clobbers SRC) and lightly transformed for vasm: `SECTION BSS` gets explicit
# attributes, because vasm's vobj output types named sections as code (only its
# TOS writer maps TEXT/DATA/BSS by name) and vlink then rejects the mix.
# SRC/ stays pristine Devpac syntax.
mkdir -p "$BUILD"
find "$BUILD" -maxdepth 1 \( -type l -o -name '*.S' -o -name '*.I' -o -name '*.H' \) -delete
SECFIX='s/^([[:space:]]*)SECTION[[:space:]]+BSS([[:space:]]*)$/\1BSS\2/; s/^([[:space:]]*)SECTION[[:space:]]+DATA([[:space:]]*)$/\1DATA\2/'
for f in "$SRC"/*.I "$SRC"/*.S "$SRC"/*.H; do
    sed -E "$SECFIX" "$f" > "$BUILD/$(basename "$f")"
done
sed -E "$SECFIX" "$SRC/$BUS_VARIANT" > "$BUILD/BUS.I"
echo "bus variant: $BUS_VARIANT   cpu: $CPU"

# PUTBUS_DYN=1: replace putBUSi's static-displacement write with the dynamic
# putBUS form (the only write form the HT2 test -- proven on hardware -- uses)
if [ -n "${PUTBUS_DYN:-}" ]; then
    sed -i 's|tst.b\t((\\2<<8)!(\\1))<<1(RcBUS)\t; write by reading|putBUS\t#\\1,\\2|' "$BUILD/BUS.I"
    echo "putBUSi:     aliased to dynamic putBUS form"
fi

# DEBUG=1: enable the driver's built-in debug printouts (DEVSWIT.I levels)
if [ -n "${DEBUG:-}" ]; then
    sed -i -E 's/^(RXDEBPRT[[:space:]]+EQU[[:space:]]+)0/\14/;
               s/^(TXDEBPRT[[:space:]]+EQU[[:space:]]+)0/\14/;
               s/^(MACAddDEBPRT[[:space:]]+EQU[[:space:]]+)0/\11/;
               s/^(PARANOIA[[:space:]]+EQU[[:space:]]+)0/\11/' "$BUILD/DEVSWIT.I"
    echo "debug:       RX/TX printout level 4, MAC PROM dump on"
fi

VASMBASE="vasmm68k_mot $CPU -devpac -quiet -I $BUILD ${RECOVER:+-DNE_RECOVER=$RECOVER}"
[ -n "${RECOVER:-}" ] && echo "recovery pad: NE_RECOVER=$RECOVER nops/access"
VASM="$VASMBASE -Ftos"

# --- targets -----------------------------------------------------------------
case "$TARGET" in
  ht1) SRCFILE=HT1ENE.S  ; OUT=HT1ENEC.TOS ;;
  ht2) SRCFILE=HT2ENE.S  ; OUT=HT2ENEC.TOS ;;
  ht3)
    # HT3 links the real NE.S driver core: three objects, linked with vlink
    # (mirrors the original tlink OBJS_HT3 = ht3ene.o ne.o uti.o)
    OUT=HT3ENEC.TOS
    for m in HT3ENE NE UTI; do
      echo "assembling $m.S -> build/$m.o"
      $VASMBASE -Fvobj "$BUILD/$m.S" -L "$BUILD/$m.lst" -o "$BUILD/$m.o"
    done
    echo "linking -> build/$OUT"
    vlink -bataritos -o "$BUILD/$OUT" "$BUILD/HT3ENE.o" "$BUILD/NE.o" "$BUILD/UTI.o"
    ls -l "$BUILD/$OUT"; file "$BUILD/$OUT"

    # --- alignment check (hardware-verified rule) --------------------------
    # Cartridge read loops work when their first read instruction sits at
    # addr%4==2 and fail at addr%4==0 (6/6 correlation on real TT). The
    # sources pin the sites with CNOP 2,4; verify the LINKED result.
    htsize=$(vobjdump "$BUILD/HT3ENE.o" | grep -A1 'SECTION "TEXT"' | grep -oE 'Total size: [0-9]+' | grep -oE '[0-9]+')
    nealign=$(vobjdump "$BUILD/NE.o" | grep -A1 'SECTION "TEXT"' | grep -oE 'Alignment: [0-9]+' | grep -oE '[0-9]+')
    nebase=$(( (htsize + nealign - 1) / nealign * nealign ))
    t2hex=$(awk '/\.t2[ \t]/{f=1} f&&/^01:[0-9A-F]{8}/{print substr($1,4,8); exit}' "$BUILD/NE.lst")
    [ -z "$t2hex" ] && { echo "ALIGNMENT CHECK FAILED: .t2 not found in NE.lst" >&2; exit 3; }
    t2=$((16#$t2hex))
    phase=$(( (nebase + t2) % 4 ))
    if [ "$phase" -ne 2 ]; then
        echo "ALIGNMENT CHECK FAILED: probe read loop at phase $phase (must be 2)" >&2
        exit 3
    fi
    echo "alignment check: probe read loop at phase 2 -- OK"
    exit 0 ;;
  ht4) SRCFILE=HT4ENEC.S ; OUT=HT4ENEC.TOS ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

echo "assembling $SRCFILE -> build/$OUT"
$VASM "$BUILD/$SRCFILE" -L "$BUILD/${OUT%.TOS}.lst" -o "$BUILD/$OUT"
echo
ls -l "$BUILD/$OUT"
file "$BUILD/$OUT"
