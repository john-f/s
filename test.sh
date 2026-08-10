#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/s-test.XXXXXXXX")"

cleanup() {
  find "$test_tmp" -mindepth 1 -delete
  rmdir "$test_tmp"
}
trap cleanup EXIT

export PATH="$repo_dir/tests/mocks:$PATH"
export S_TEST_LOG="$test_tmp/call.log"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_call() {
  local expected="$1"
  grep -Fxq -- "$expected" "$S_TEST_LOG" \
    || fail "expected call '$expected', got '$(cat "$S_TEST_LOG" 2>/dev/null || true)'"
}

# New shpool releases align names and emit NAME<TAB>STATUS.
export S_TEST_LIST_OUTPUT=$'NAME\tSTATUS\nalpha   \tdisconnected\nbeta    \tattached\n'
"$repo_dir/s"
assert_call 'attach -f -- alpha'

# Older shpool releases emitted NAME<TAB>STARTED_AT<TAB>STATUS.
export S_TEST_LIST_OUTPUT=$'NAME\tSTARTED_AT\tSTATUS\nlegacy\t2026-01-01T00:00:00Z\tdisconnected\n'
"$repo_dir/s"
assert_call 'attach -f -- legacy'

# A named session bypasses the picker and remains one argument.
"$repo_dir/s" 'name;still-one-argument'
assert_call 'attach -f -- name;still-one-argument'

# With no sessions, create a date-named session without forcing a detach.
export S_TEST_LIST_OUTPUT=$'NAME\tSTATUS\n'
"$repo_dir/s"
grep -Eq '^attach -- [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$S_TEST_LOG" \
  || fail "unexpected default-session call: $(cat "$S_TEST_LOG")"

# Preview requests use hardcopy and honor the requested line count.
export S_TEST_HARDCOPY_OUTPUT=$'one\ntwo\nthree\n'
preview="$("$repo_dir/s" --preview alpha 2)"
[ "$preview" = $'two\nthree' ] || fail "unexpected preview: $preview"
assert_call 'hardcopy -- alpha'

# Remote selection parses the same list format and quotes the remote command.
export S_TEST_LIST_OUTPUT=$'NAME\tSTATUS\nremote-one  \tdisconnected\n'
"$repo_dir/s" @devbox
grep -Fq -- 'devbox exec shpool attach -f -- remote-one' "$S_TEST_LOG" \
  || fail "unexpected remote call: $(cat "$S_TEST_LOG")"

echo "all tests passed"
