.PHONY: build build-release test clean run bundle bundle-release verify-bundle archive-release

build:
	swift build

build-release:
	swift build -c release

test:
	swift test

clean:
	rm -rf .build/ "Sage Bar.app" "Sage-Bar-local.zip"

run:
	swift run SageBar

bundle: build
	@./scripts/bundle_app.sh \
		--binary .build/debug/SageBar \
		--resources-bundle .build/debug/SageBar_SageBar.bundle \
		--sparkle-framework .build/debug/Sparkle.framework \
		--output "Sage Bar.app" \
		--codesign-identity -

bundle-release: build-release
	@./scripts/bundle_app.sh \
		--binary .build/release/SageBar \
		--resources-bundle .build/release/SageBar_SageBar.bundle \
		--sparkle-framework .build/release/Sparkle.framework \
		--output "Sage Bar.app" \
		--codesign-identity -

verify-bundle: bundle
	@./scripts/verify_app_bundle.sh --app "Sage Bar.app" --skip-spctl --smoke-launch

archive-release: bundle-release
	@ditto -c -k --sequesterRsrc --keepParent "Sage Bar.app" "Sage-Bar-local.zip"
