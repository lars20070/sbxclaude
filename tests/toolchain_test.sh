#!/usr/bin/env bash
# Smoke-tests the helper toolchain from inside a live sbxclaude sandbox.
set -euo pipefail

TESTS=0

fail() {
	echo "not ok - $*" >&2
	exit 1
}

pass() {
	TESTS=$((TESTS + 1))
	echo "ok ${TESTS} - $*"
}

check_tool() {
	local tool="$1"
	shift
	local output

	command -v "${tool}" >/dev/null 2>&1 ||
		fail "${tool} is not on PATH"
	if ! output="$("$@" 2>&1)"; then
		fail "${tool} version command failed"
	fi
	[[ -n "${output}" ]] || fail "${tool} version command produced no output"
	pass "${tool} is available"
}

check_tool jq jq --version
check_tool rg rg --version
check_tool curl curl --version
check_tool python3 python3 --version
check_tool shellcheck shellcheck --version
check_tool ruff ruff --version
check_tool yamllint yamllint --version
check_tool markdownlint-cli2 markdownlint-cli2 --version
check_tool cspell cspell --version
check_tool sbx sbx version

CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
[[ -s "${CA_BUNDLE}" ]] || fail "CA certificate bundle is missing or empty"
pass "CA certificate bundle is available"

echo "All ${TESTS} toolchain tests passed."
