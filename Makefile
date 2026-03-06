.PHONY: build test clean run run-cli

build:
	swift build

test:
	swift test

clean:
	rm -rf .build/

run:
	swift run ClaudeUsage

run-cli:
	swift run claude-usage
