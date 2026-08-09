MARKDOWNLINT ?= markdownlint-cli2
YAMLLINT ?= yamllint
CSPELL ?= cspell

.PHONY: lint test validate

# Lint tracked Markdown, JSON, YAML, and shell scripts.
lint:
	git ls-files -z -- '*.md' | xargs -0 $(MARKDOWNLINT)
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	git ls-files -z -- '*.yaml' '*.yml' | xargs -0 $(YAMLLINT)
	$(CSPELL) "**/*.md" "scripts/**"
	shellcheck --enable=all scripts/sbxclaude tests/sbxclaude_test.sh
	bash -n scripts/sbxclaude
	@echo "All lint checks passed."

# Test the wrapper with a fake sbx CLI.
test:
	./tests/sbxclaude_test.sh

# Validate the sandbox kit spec against the current Sandbox Kit schema.
validate:
	./scripts/sbxclaude kit validate
