#!/bin/bash -eu
# Copyright 2026 Pau Aliagas <linuxnow@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Builds reac-pw's seven fuzz targets (fuzz/fuzz_*.c in the reac-pw repository) into $OUT.
# reac-pw's own fuzz/build.sh builds them with a native clang and libFuzzer; this script makes
# the same harnesses into static riscv64 programs, each linked against a static library of the
# readers of this build. No fuzz target links libreac: they use its headers and SPA's, from the
# sources file, and the box-model table of fuzz/catalogue.c.

INC=(-Isrc -Ifacts -Ifuzz -I"$SRC/libreac/include" -I"$SRC/pipewire/spa/include")
# as meson compiles reac-pw (C11, _GNU_SOURCE), with the flags of libspa-0.2.pc
STD=(-std=c11 -D_GNU_SOURCE -D_REENTRANT -fno-strict-aliasing)
# The two readers of rtnetlink replies, compiled with their socket calls renamed to the fake
# kernel of fuzz/netlink.h, as fuzz/build.sh compiles them: the rename at the compile is the
# way docs/build-contract.md gives for functions the AddressSanitizer runtime wraps.
NET=(-U_FORTIFY_SOURCE -Dsocket=fuzz_socket -Dsend=fuzz_send -Drecv=fuzz_recv -Dclose=fuzz_close
     -Dif_nametoindex=fuzz_if_nametoindex)

# The library: the readers the fuzz targets drive, and the box-model table, in a fixed order.
mkdir -p "$WORK/obj"
objs=()
for src in src/reac_segconf.c src/reac_declared_vlan.c src/reac_box_pin.c src/reac_headamp_prop.c \
           src/reac_rate_cfg.c src/reac_role_cfg.c src/reac_qdisc.c src/reac_link_alias.c \
           src/reac_served_mark.c src/reac_knock_wire.c fuzz/catalogue.c; do
  extra=()
  case $src in
  src/reac_qdisc.c | src/reac_link_alias.c) extra=("${NET[@]}") ;;
  esac
  obj="$WORK/obj/$(basename "$src" .c).o"
  $CC $CFLAGS "${STD[@]}" "${INC[@]}" "${extra[@]}" -c "$src" -o "$obj"
  objs+=("$obj")
done
$AR rcs "$WORK/libreac-pw-readers.a" "${objs[@]}"

# src/reac_knock_wire.c is linked for its plan table alone, which reac_segconf.c reads a
# `knock =` name through. The rest of that file calls the libreac library and reac-pw's own
# wake ladder, which no fuzz target compiles, and fuzz_segconf calls none of it. Each of
# those calls is linked here as a stop that calls abort(), so every symbol of every target
# resolves: a link that drops a real object says so, and a call that is one day reached
# ends the run at the call instead of jumping to address 0.
cat > "$WORK/knock_stubs.c" <<'EOF'
#include <stdlib.h>
#define STOP(name) void name(void); void name(void) { abort(); }
STOP(reac_ctrl_parse)
STOP(reac_downstream_build)
STOP(reac_knock_heard)
STOP(reac_knock_init)
STOP(reac_knock_step)
STOP(reac_master_init)
STOP(reac_master_next)
STOP(reac_master_stamp)
STOP(reac_pace_code)
STOP(reac_wake_init)
STOP(reac_wake_reopen)
STOP(reac_wake_step)
EOF
$CC $CFLAGS "${STD[@]}" -c "$WORK/knock_stubs.c" -o "$WORK/knock_stubs.o"

# The fuzz targets.
for h in segconf pin headamp rate role qdisc link; do
  stubs=()
  [ "$h" = segconf ] && stubs=("$WORK/knock_stubs.o")
  $CC $CFLAGS "${STD[@]}" "${INC[@]}" -c "fuzz/fuzz_$h.c" -o "$WORK/fuzz_$h.o"
  $CC $CFLAGS "$WORK/fuzz_$h.o" -o "$OUT/fuzz_$h" $LIB_FUZZING_ENGINE "$WORK/libreac-pw-readers.a" \
    "${stubs[@]}" -lm
done
