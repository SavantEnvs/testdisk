#!/usr/bin/env bash
#
# mayhem/test.sh — known-answer oracle for upstream's `fidentify` (file-signature identifier), built by
# mayhem/build.sh with normal flags into mayhem/bin/. Upstream ships no test suite of its own; this feeds
# fixed byte streams (mayhem/fuzzerfidentify/testsuite/*) through fidentify and asserts the exact
# identification + size it prints. A no-op program prints nothing and fails every case.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


FID="$SRC/mayhem/bin/fidentify"
SEEDS="$SRC/mayhem/fuzzerfidentify/testsuite"
[ -x "$FID" ] || { echo "missing $FID — mayhem/build.sh did not build it" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

passed=0; failed=0
expect() {  # expect <name> <expected> <actual>
  if [ "$2" = "$3" ]; then passed=$((passed+1)); echo "ok   $1"
  else failed=$((failed+1)); echo "FAIL $1: expected [$2] got [$3]"; fi
}

for spec in "gif.gif:gif file_size=43" "png.png:png file_size=69" "pdf.pdf:pdf file_size=69" \
            "wav.wav:wav file_size=44" "bmp.bmp:unknown" "elf.elf:unknown" "jpg.jpg:unknown" "zip.zip:unknown"; do
  name="${spec%%:*}"; want="${spec#*:}"
  got="$("$FID" --check "$SEEDS/$name" 2>/dev/null | sed -n "s#^$SEEDS/$name: ##p")"
  expect "identify $name" "$want" "$got"
done

# +<ext> restricts detection to one format: only the PNG is recognised in the whole directory.
got="$("$FID" --check +png "$SEEDS" 2>/dev/null | grep -v ': unknown$' | sed "s#^$SEEDS/##")"
expect "+png filter over seed dir" "png.png: png file_size=69" "$got"

# A PNG with a corrupted signature byte must NOT be identified as png.
{ printf '\211PNX\r\n\032\n'; tail -c +9 "$SEEDS/png.png"; } > badsig.png
got="$("$FID" badsig.png 2>/dev/null)"
expect "corrupted png signature" "badsig.png: unknown" "$got"

head -c 100 /dev/zero > zeros.bin
got="$("$FID" zeros.bin 2>/dev/null)"
expect "zero-filled stream" "zeros.bin: dovecot" "$got"

emit_ctrf "fidentify-known-answer" "$passed" "$failed" 0
