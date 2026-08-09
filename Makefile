.PHONY: validate-kit

# Validate the sandbox kit spec against the current Sandbox Kit schema.
validate-kit:
	./scripts/sbxclaude --validate