#!/usr/bin/env bash
# Smoke-tests the helper toolchain from inside a live sbxclaude sandbox.
# Keep EXPECTED_* in sync with the pinned installs in sbxclaude/spec.yaml.
set -euo pipefail

EXPECTED_SBX_VERSION="v0.38.0"
EXPECTED_RUFF_VERSION="0.16.2"
EXPECTED_YAMLLINT_VERSION="1.38.0"
EXPECTED_MARKDOWNLINT_VERSION="0.23.2"
EXPECTED_CSPELL_VERSION="10.0.1"

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

check_tool_version() {
	local tool="$1"
	local expected="$2"
	shift 2
	local output

	command -v "${tool}" >/dev/null 2>&1 ||
		fail "${tool} is not on PATH"
	if ! output="$("$@" 2>&1)"; then
		fail "${tool} version command failed"
	fi
	[[ -n "${output}" ]] || fail "${tool} version command produced no output"
	printf '%s\n' "${output}" | grep -Fqw "${expected}" ||
		fail "${tool} version mismatch: expected '${expected}' in: ${output}"
	pass "${tool} is ${expected}"
}

# Distro / parent-kit tools: presence only.
check_tool jq jq --version
check_tool rg rg --version
check_tool curl curl --version
check_tool python3 python3 --version
check_tool shellcheck shellcheck --version
check_tool git git --version

# Directly installed tools: exact pinned versions.
check_tool_version ruff "${EXPECTED_RUFF_VERSION}" ruff --version
check_tool_version yamllint "${EXPECTED_YAMLLINT_VERSION}" yamllint --version
check_tool_version markdownlint-cli2 "v${EXPECTED_MARKDOWNLINT_VERSION}" markdownlint-cli2 --version
check_tool_version cspell "${EXPECTED_CSPELL_VERSION}" cspell --version
check_tool_version sbx "${EXPECTED_SBX_VERSION}" sbx version

CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
[[ -s "${CA_BUNDLE}" ]] || fail "CA certificate bundle is missing or empty"
pass "CA certificate bundle is available"

# Sandbox policy allows github.com:443 but not SSH port 22; the kit rewrites
# GitHub SSH remotes to HTTPS so fetches stay on the allowlist.
INSTEAD_OF="$(git config --global --get-all url.https://github.com/.insteadOf || true)"
printf '%s\n' "${INSTEAD_OF}" | grep -Fxq 'git@github.com:' ||
	fail "missing insteadOf rewrite for git@github.com:"
printf '%s\n' "${INSTEAD_OF}" | grep -Fxq 'ssh://git@github.com/' ||
	fail "missing insteadOf rewrite for ssh://git@github.com/"
pass "GitHub SSH remotes rewrite to HTTPS"

echo "All ${TESTS} toolchain tests passed."
