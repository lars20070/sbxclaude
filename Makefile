MARKDOWNLINT ?= markdownlint-cli2

.PHONY: lint validate-kit

# Lint tracked Markdown, JSON, and shell script.
lint:
	git ls-files -z -- '*.md' | xargs -0 $(MARKDOWNLINT)
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	shellcheck --enable=all scripts/sbxclaude
	@echo "All lint checks passed."

# Validate the sandbox kit spec against the current Sandbox Kit schema.
validate-kit:
	./scripts/sbxclaude --validate
