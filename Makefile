MARKDOWNLINT ?= markdownlint-cli2
YAMLLINT ?= yamllint
CSPELL ?= cspell

.PHONY: lint validate test test-unit test-toolchain

# Lint tracked Markdown, JSON, YAML, and shell scripts, and spell-check
# everything tracked.
lint:
	git ls-files -z -- '*.md' | xargs -0 $(MARKDOWNLINT)
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	git ls-files -z -- '*.yaml' '*.yml' | xargs -0 $(YAMLLINT)
	git ls-files -z -- '*.sh' 'scripts/*' | xargs -0 shellcheck --enable=all
	# `bash -n` only parses its first file argument, so feed it one at a time.
	git ls-files -z -- '*.sh' 'scripts/*' | xargs -0 -n1 bash -n
	git ls-files -z | xargs -0 $(CSPELL) --no-progress
	@echo "All lint checks passed."

# Validate the sandbox kit spec against the current Sandbox Kit schema.
validate:
	./scripts/sbxclaude kit validate

# Run every test
test: test-unit test-toolchain

# Test the wrapper with a fake sbx CLI.
test-unit:
	./tests/sbxclaude_test.sh

# Smoke-test the installed helper tools inside the live sandbox.
test-toolchain:
	./scripts/sbxclaude exec ./tests/toolchain_test.sh
