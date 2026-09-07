#!/usr/bin/env bash
# Usage: cft [source.cpp]
# No argument: find the current problem's <directory-name>.cpp.
# Explicit source: use the tests/ directory beside that source.
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Usage: %s [source.cpp]\n' "$0"
    printf 'Environment: CXX, ACL_DIR, CF_TEST_TIMEOUT (default 5 seconds).\n'
    exit 0
fi

if (( $# > 1 )); then
    printf 'Usage: %s [source.cpp]\n' "$0" >&2
    exit 2
fi

CXX=${CXX:-g++}
TIMEOUT=${CF_TEST_TIMEOUT:-5}
ACL_DIR=${ACL_DIR:-"$HOME/contests/acl"}

for cmd in "$CXX" timeout python3 find sort mktemp head sed wc dirname basename; do
    command -v "$cmd" >/dev/null || {
        printf 'Missing command: %s\n' "$cmd" >&2
        exit 2
    }
done

TIMEOUT=$(python3 - "$TIMEOUT" <<'PY_TIME'
import math, sys
try:
    n = float(sys.argv[1])
    if not math.isfinite(n) or n <= 0:
        raise ValueError
except ValueError:
    print(
        'CF_TEST_TIMEOUT must be finite and greater than zero.',
        file=sys.stderr,
    )
    raise SystemExit(2)
print(n)
PY_TIME
)

# Resolve the source and its problem directory.
if (( $# == 1 )); then
    [[ -f "$1" ]] || {
        printf 'Source not found: %s\n' "$1" >&2
        exit 2
    }

    PROBLEM_DIR=$(cd -P -- "$(dirname -- "$1")" && pwd -P)
    SRC="$PROBLEM_DIR/$(basename -- "$1")"
else
    PROBLEM_DIR=$(pwd -P)

    while :; do
        name=${PROBLEM_DIR##*/}
        SRC="$PROBLEM_DIR/$name.cpp"

        if [[ -f "$SRC" && -d "$PROBLEM_DIR/tests" ]]; then
            break
        fi

        if [[ "$PROBLEM_DIR" == / ]]; then
            printf 'No current problem found. cd into a problem, or pass its .cpp path.\n' >&2
            exit 2
        fi

        PROBLEM_DIR=${PROBLEM_DIR%/*}
        PROBLEM_DIR=${PROBLEM_DIR:-/}
    done
fi

TEST_DIR="$PROBLEM_DIR/tests"
[[ -d "$TEST_DIR" ]] || {
    printf 'Missing tests directory: %s\n' "$TEST_DIR" >&2
    exit 2
}

RED='' GREEN='' CYAN='' BOLD='' RESET=''
if [[ -t 1 && -z ${NO_COLOR+x} ]]; then
    RED=$'\033[91m'
    GREEN=$'\033[92m'
    CYAN=$'\033[96m'
    BOLD=$'\033[1m'
    RESET=$'\033[0m'
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/cf-test.XXXXXXXX")
RUNNER=''

cleanup() {
    if [[ -n "$RUNNER" ]]; then
        # GNU timeout creates its own process group.
        kill -KILL -- "-$RUNNER" 2>/dev/null \
            || kill -KILL "$RUNNER" 2>/dev/null \
            || :
        wait "$RUNNER" 2>/dev/null || :
    fi
    rm -rf -- "$TMP"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# NUL-separated paths support spaces.
# Version sorting puts 2 before 10.
if ! find "$TEST_DIR" -type f \
    \( -name '*.in' -o -name '*.out' \) -print0 \
    | LC_ALL=C sort -z -V > "$TMP/files"; then
    printf 'Could not enumerate test files.\n' >&2
    exit 2
fi

TESTS=()
while IFS= read -r -d '' file; do
    case "$file" in
        *.in)
            [[ -f "${file%.in}.out" ]] || {
                printf 'Missing answer: %s\n' "${file%.in}.out" >&2
                exit 2
            }
            TESTS+=("$file")
            ;;
        *.out)
            [[ -f "${file%.out}.in" ]] || {
                printf 'Answer has no input: %s\n' "$file" >&2
                exit 2
            }
            ;;
    esac
done < "$TMP/files"

if (( ${#TESTS[@]} == 0 )); then
    printf 'No .in/.out test pairs under %s\n' "$TEST_DIR" >&2
    exit 2
fi

show_file() {
    head -c 6000 -- "$1" | sed 's/^/      /'
    printf '\n'
    if (( $(wc -c < "$1") > 6000 )); then
        printf '      ... display truncated ...\n'
    fi
}

cat > "$TMP/compare.py" <<'PY_COMPARE'
import sys
from pathlib import Path

try:
    expected = Path(sys.argv[1]).read_bytes()
    actual = Path(sys.argv[2]).read_bytes()
except OSError as e:
    print(f'Comparison error: {e}', file=sys.stderr)
    raise SystemExit(2)

# Whitespace-token comparison; stderr is never part of the answer.
raise SystemExit(0 if expected.split() == actual.split() else 1)
PY_COMPARE

BIN="$TMP/program"
FLAGS=(
    -std=c++20
    -O2
    -DLOCAL
    -Wall
    -Wextra
    -Wshadow
    "-I$ACL_DIR"
)

printf '%sCompiling:%s' "$CYAN" "$RESET"
printf ' %q' "$CXX" "${FLAGS[@]}" "$SRC" -o "$BIN"
printf '\n\n'

# Relative program files use the problem directory.
cd -- "$PROBLEM_DIR"

if ! "$CXX" "${FLAGS[@]}" "$SRC" -o "$BIN"; then
    printf '%sCompilation failed%s\n' "$RED" "$RESET" >&2
    exit 2
fi

PASSED=0
TOTAL=${#TESTS[@]}

for inf in "${TESTS[@]}"; do
    ansf="${inf%.in}.out"
    label=${inf#"$TEST_DIR/"}
    got="$TMP/actual.out"
    err="$TMP/stderr.txt"

    (
        ulimit -c 0

        # Bound regular-file output without raising a stricter limit.
        size_limit=$(ulimit -f)
        if [[ "$size_limit" == unlimited ]] || (( size_limit > 16384 )); then
            ulimit -f 16384
        fi

        exec timeout --kill-after=1s "$TIMEOUT" "$BIN"
    ) < "$inf" > "$got" 2> "$err" &

    RUNNER=$!
    if wait "$RUNNER" 2>/dev/null; then
        STATUS=0
    else
        STATUS=$?
    fi
    RUNNER=''

    case "$STATUS" in
        0)
            if python3 "$TMP/compare.py" "$ansf" "$got"; then
                printf '  %s: %sPASS%s\n' "$label" "$GREEN" "$RESET"

                # Unlike ((PASSED++)), this is safe under set -e.
                PASSED=$((PASSED + 1))
            else
                compare_status=$?
                if (( compare_status != 1 )); then
                    exit 2
                fi

                printf '  %s: %sWA%s\n' "$label" "$RED" "$RESET"
                printf '    %sinput:%s\n' "$BOLD" "$RESET"
                show_file "$inf"
                printf '    %sexpected:%s\n' "$BOLD" "$RESET"
                show_file "$ansf"
                printf '    %sactual:%s\n' "$BOLD" "$RESET"
                show_file "$got"
            fi
            ;;
        124)
            printf '  %s: %sTLE%s (%ss local wall limit)\n' \
                "$label" "$RED" "$RESET" "$TIMEOUT"
            ;;
        137)
            printf '  %s: %sKILLED%s (SIGKILL: timeout escalation or external kill)\n' \
                "$label" "$RED" "$RESET"
            ;;
        *)
            printf '  %s: %sRTE%s (exit %s)\n' \
                "$label" "$RED" "$RESET" "$STATUS"
            ;;
    esac

    if [[ -s "$err" ]]; then
        printf '    %sstderr/debug:%s\n' "$CYAN" "$RESET"
        show_file "$err"
    fi
done

printf '\n%d/%d local tests passed\n' "$PASSED" "$TOTAL"

if (( PASSED == TOTAL )); then
    exit 0
else
    exit 1
fi
