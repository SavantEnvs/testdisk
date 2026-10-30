#!/usr/bin/env bash
#
# mayhem/build.sh — build the fuzzerfidentify libFuzzer harness (upstream's own src/fuzzerfidentify.cpp),
# its standalone reproducer, and the fidentify binary that mayhem/test.sh drives.
# Runs in /mayhem as `mayhem`; re-runnable and offline (autotools only, no fetches).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Generate configure (all outputs are covered by upstream's .gitignore) and configure once with plain flags;
# the sanitized/normal variants below only override flags on the `make` command line.
mkdir -p config
autoreconf --install -I config
./configure CC="$CC" CXX="$CXX" --disable-qt --without-ntfs --without-ntfs3g --without-ewf --without-reiserfs

# 1) Test oracle: fidentify with the project's NORMAL flags, staged where mayhem/test.sh looks.
make -C src clean >/dev/null 2>&1 || true
make -C src -j"$MAYHEM_JOBS" fidentify CFLAGS="-O2 $COVERAGE_FLAGS" CXXFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
mkdir -p "$SRC/mayhem/bin"
cp src/fidentify "$SRC/mayhem/bin/fidentify"

# 2) Fuzz build: the whole project instrumented (ASan+UBSan halting, coverage, DWARF-3), harness linked with
# libFuzzer; a second link with LLVM's run-once driver gives the standalone reproducer. LSan is switched off at
# build time by linking mayhem/lsan_off.cc.
make -C src clean >/dev/null 2>&1 || true
rm -f src/fuzzerfidentify
LSAN_OFF=/tmp/lsan_off.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
FIDENTIFY_LDADD="$(sed -n 's/^fidentify_LDADD *= *//p' src/Makefile)"
# UBSan `alignment` is relaxed project-wide: the format parsers cast byte buffers to wider integer pointers all over
# (e.g. file_gpg.c:608 `(const uint16_t *)&buffer[i+...]`), which is benign on x86 but fires within seconds and
# halts the fuzzer before it reaches deeper code. Everything else in UBSan and ASan stays on and halting.
FUZZ_FLAGS="$SANITIZER_FLAGS -fno-sanitize=alignment $DEBUG_FLAGS -O1"
[ -z "$SANITIZER_FLAGS" ] || FUZZ_FLAGS="$FUZZ_FLAGS -fsanitize=fuzzer-no-link"

# The three objects that walk upstream's intrusive lists (filegen.c, file_sig.c, the harness) are compiled with UBSan
# `null` and `object-size` relaxed too: td_list_entry() is the classic `&((type *)0)->member` offsetof idiom,
# which trips the type-mismatch check on every input. ASan still catches real null dereferences, and the rest of
# the project keeps full UBSan.
RELAX="-fno-sanitize=null,object-size"
make -C src filegen.o file_sig.o CFLAGS="$FUZZ_FLAGS $RELAX"
make -C src fuzzerfidentify.o CXXFLAGS="$FUZZ_FLAGS $RELAX"
make -C src -j"$MAYHEM_JOBS" fuzzerfidentify \
  CFLAGS="$FUZZ_FLAGS" CXXFLAGS="$FUZZ_FLAGS" LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $LSAN_OFF"
cp src/fuzzerfidentify /mayhem/fuzzerfidentify
rm -f src/fuzzerfidentify

make -C src fuzzerfidentify \
  CFLAGS="$FUZZ_FLAGS" CXXFLAGS="$FUZZ_FLAGS" LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $LSAN_OFF /tmp/standalone_main.o" \
  fuzzerfidentify_LDADD="$FIDENTIFY_LDADD"
cp src/fuzzerfidentify /mayhem/fuzzerfidentify-standalone
rm -f src/fuzzerfidentify
