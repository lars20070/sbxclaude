.PHONY: lint validate-kit

# Lint tracked Markdown, JSON, and shell script.
lint:
	git ls-files -z -- '*.md' | xargs -0 markdownlint-cli2
	git ls-files -z -- '*.json' | xargs -0 -n1 jq empty
	shellcheck --enable=all scripts/sbxclaude

# Validate the sandbox kit spec against the current Sandbox Kit schema.
validate-kit:
	./scripts/sbxclaude --validate
