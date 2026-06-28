#!/usr/bin/env bash
#
# Native-link regression guardrail.
#
# The cross-compilation work makes the PE/COFF link path reachable from non-Windows
# hosts. That change must be PURELY ADDITIVE: a native build (Linux->Linux,
# macOS->macOS) must keep selecting its native linker and must keep producing
# the same structural link command line as before.
#
# This script protects that invariant continuously in CI. It builds a tiny
# program natively with -show-system-calls so the linker command line is
# printed, then enforces two tiers of checks:
#
#   Tier A (always enforced, no machine-specific baseline needed):
#     * the native build must NOT hit the cross-compile "not yet supported"
#       path that the odin-cross work relaxes;
#     * a native linker SYSTEM CALL ("[SYSTEM CALL] *-link") must be emitted;
#     * a set of structural tokens that src/linker.cpp emits as string
#       literals for the native link command must all be present (these are the
#       flags a regression in the additive cross work would most likely drop or
#       reorder away).
#
#   Tier B (full normalized command-line baseline diff):
#     * the entire native link command line, with volatile pieces (absolute
#       toolchain paths, temp object files, output path, ODIN_ROOT, thread
#       counts) normalized to placeholders, is diffed against a checked-in
#       baseline. If no baseline exists for this host it is auto-recorded and
#       the run passes with a notice -- so the very first CI run on a new host
#       locks in current native behavior instead of failing spuriously.
#
# A smoke run of the natively linked binary confirms it actually executes.
#
# Regenerate the Tier B baseline after an intentional, reviewed change:
#       ODIN=./odin tests/cross/native_link_regression.sh --update
# and commit the updated baseline file.
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ODIN="${ODIN:-$REPO_ROOT/odin}"
SRC="$SCRIPT_DIR/hello.odin"

UPDATE_BASELINE=0
if [[ "${1:-}" == "--update" || "${1:-}" == "-u" ]]; then
	UPDATE_BASELINE=1
fi

OS_NAME="$(uname -s)"
case "$OS_NAME" in
	Linux)  BASELINE="$SCRIPT_DIR/baselines/linux_native_link.txt" ;;
	Darwin) BASELINE="$SCRIPT_DIR/baselines/darwin_native_link.txt" ;;
	*)      BASELINE="$SCRIPT_DIR/baselines/$(echo "$OS_NAME" | tr '[:upper:]' '[:lower:]')_native_link.txt" ;;
esac

# Structural tokens that must appear in the native link command line. These are
# string literals emitted by src/linker.cpp for the non-Windows clang-driver
# link path; a regression in the additive cross work would most likely drop one.
REQUIRED_TOKENS=(
	"-Wno-unused-command-line-argument"
	"-o "
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

OUT="$WORK/hello_regression"
RAW_LOG="$WORK/raw.log"

echo "[native-link-regression] building $SRC natively with $ODIN"
set +e
"$ODIN" build "$SRC" -file -show-system-calls -keep-temp-files -out:"$OUT" >"$RAW_LOG" 2>&1
BUILD_RC=$?
set -e

if [[ $BUILD_RC -ne 0 ]]; then
	echo "[native-link-regression] FAIL: native build returned non-zero exit ($BUILD_RC)"
	echo "----- build output -----"; cat "$RAW_LOG"; echo "------------------------"
	exit 1
fi

# Tier A.1: a native build must never be routed through the cross-compile
# "not yet supported" path relaxed by the odin-cross work.
if grep -qi "not yet supported" "$RAW_LOG"; then
	echo "[native-link-regression] FAIL: native build hit the cross-compile 'not yet supported' path."
	echo "    The cross changes leaked into the native link path -- they must be additive."
	cat "$RAW_LOG"
	exit 1
fi

# Extract the LAST [SYSTEM CALL] block whose tag ends in "-link" (ld-link,
# lld-link, mold-link). -show-system-calls prints the tag on one line and the
# command line on the next.
LINKER_TAG=""
LINKER_CMD=""
saw_tag=0
while IFS= read -r line; do
	if [[ $saw_tag -eq 1 ]]; then
		LINKER_CMD="$line"
		saw_tag=0
		continue
	fi
	if [[ "$line" == "[SYSTEM CALL] "*-link ]]; then
		LINKER_TAG="${line#\[SYSTEM CALL\] }"
		saw_tag=1
	fi
done < "$RAW_LOG"

# Tier A.2: a native link step with a native linker tag must have run.
if [[ -z "$LINKER_TAG" || -z "$LINKER_CMD" ]]; then
	echo "[native-link-regression] FAIL: no native linker SYSTEM CALL was found."
	echo "    Expected a '[SYSTEM CALL] *-link' line from src/linker.cpp."
	echo "----- build output -----"; cat "$RAW_LOG"; echo "------------------------"
	exit 1
fi

# Tier A.3: required structural tokens must all be present.
MISSING=0
for tok in "${REQUIRED_TOKENS[@]}"; do
	if [[ "$LINKER_CMD" != *"$tok"* ]]; then
		echo "[native-link-regression] FAIL: native link command line is missing required token: '$tok'"
		MISSING=1
	fi
done
if [[ $MISSING -ne 0 ]]; then
	echo "----- native link command line -----"
	echo "[SYSTEM CALL] $LINKER_TAG"
	echo "$LINKER_CMD"
	echo "------------------------------------"
	exit 1
fi

# Normalize volatile pieces so the Tier B baseline survives runner-image churn
# while still catching real structural changes (added/removed/reordered flags
# or libraries).
normalize() {
	sed \
		-e "s#${WORK}#<WORK>#g" \
		-e "s#${OUT}#<OUT>#g" \
		-e "s#${REPO_ROOT}#<ROOT>#g" \
		-e 's#/tmp/[^ "]*#<TMP>#g' \
		-e 's#"[^"]*\.o"#"<OBJ>"#g' \
		-e 's#[^ ]*\.o\b#<OBJ>#g' \
		-e 's#-flto-jobs=[0-9]\+#-flto-jobs=<N>#g' \
		-e 's#  *# #g' \
		-e 's#^ *##' \
		-e 's# *$##'
}

NORMALIZED="$(printf 'TAG: %s\nCMD: %s\n' "$LINKER_TAG" "$LINKER_CMD" | normalize)"

if [[ $UPDATE_BASELINE -eq 1 ]]; then
	mkdir -p "$(dirname "$BASELINE")"
	printf '%s\n' "$NORMALIZED" > "$BASELINE"
	echo "[native-link-regression] baseline updated: $BASELINE"
	echo "----- new baseline -----"; cat "$BASELINE"; echo "------------------------"
	exit 0
fi

if [[ ! -f "$BASELINE" ]]; then
	# Auto-bootstrap so a brand-new host does not fail CI spuriously. Tier A
	# already enforced the load-bearing invariants above.
	mkdir -p "$(dirname "$BASELINE")"
	printf '%s\n' "$NORMALIZED" > "$BASELINE"
	echo "[native-link-regression] NOTICE: no baseline for $OS_NAME; recorded one at:"
	echo "    $BASELINE"
	echo "    Commit it so future runs diff against it."
else
	if ! diff -u "$BASELINE" <(printf '%s\n' "$NORMALIZED") >"$WORK/diff.txt"; then
		echo "[native-link-regression] FAIL: native link command line changed vs baseline."
		echo "    If this change is intentional, regenerate the baseline with:"
		echo "        ODIN=$ODIN $0 --update"
		echo "    and commit $BASELINE."
		echo "----- diff (baseline vs observed) -----"; cat "$WORK/diff.txt"; echo "---------------------------------------"
		exit 1
	fi
fi

echo "[native-link-regression] smoke-running native binary"
if ! "$OUT"; then
	echo "[native-link-regression] FAIL: natively linked binary did not run cleanly."
	exit 1
fi

echo "[native-link-regression] PASS: native link guardrail OK ($LINKER_TAG)."
