.PHONY: build test clean run

build:
	swift build

test:
	swift test

clean:
	rm -rf .build/

run:
	swift run SageBar
