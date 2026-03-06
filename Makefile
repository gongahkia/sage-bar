.PHONY: build test clean run bundle

build:
	swift build

test:
	swift test

clean:
	rm -rf .build/ "Sage Bar.app"

run:
	swift run SageBar

bundle: build
	@echo "Bundling Sage Bar.app..."
	@rm -rf "Sage Bar.app"
	@mkdir -p "Sage Bar.app/Contents/MacOS"
	@mkdir -p "Sage Bar.app/Contents/Resources"
	@cp .build/debug/SageBar "Sage Bar.app/Contents/MacOS/SageBar"
	@cp -R .build/debug/SageBar_SageBar.bundle "Sage Bar.app/Contents/Resources/"
	@cp Sources/ClaudeUsage/Resources/Info.plist "Sage Bar.app/Contents/"
	@if [ -f .build/debug/SageBar_SageBar.bundle/AppIcon.icns ]; then \
		cp .build/debug/SageBar_SageBar.bundle/AppIcon.icns "Sage Bar.app/Contents/Resources/AppIcon.icns"; \
	fi
	@echo "Created Sage Bar.app"
