#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bundle_app.sh --binary PATH --resources-bundle PATH [options]

Options:
  --binary PATH              Compiled SageBar executable
  --resources-bundle PATH    SwiftPM resource bundle directory
  --sparkle-framework PATH   Sparkle.framework directory to embed
  --info-plist PATH          Info.plist to copy into the bundle
  --output PATH              Output .app path (default: Sage Bar.app)
  --codesign-identity ID     Codesign identity (default: "-" for ad hoc)
  --entitlements PATH        Entitlements plist for non-ad-hoc signing
  --skip-sign                Skip codesigning entirely
EOF
}

binary_path=""
resources_bundle=""
sparkle_framework=""
info_plist="Sources/ClaudeUsage/Resources/Info.plist"
output_app="Sage Bar.app"
codesign_identity="${CODESIGN_IDENTITY:--}"
entitlements_path=""
should_sign=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      binary_path="$2"
      shift 2
      ;;
    --resources-bundle)
      resources_bundle="$2"
      shift 2
      ;;
    --sparkle-framework)
      sparkle_framework="$2"
      shift 2
      ;;
    --info-plist)
      info_plist="$2"
      shift 2
      ;;
    --output)
      output_app="$2"
      shift 2
      ;;
    --codesign-identity)
      codesign_identity="$2"
      shift 2
      ;;
    --entitlements)
      entitlements_path="$2"
      shift 2
      ;;
    --skip-sign)
      should_sign=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

[[ -f "$binary_path" ]] || { echo "Missing executable: $binary_path" >&2; exit 1; }
[[ -d "$resources_bundle" ]] || { echo "Missing resource bundle: $resources_bundle" >&2; exit 1; }
[[ -f "$info_plist" ]] || { echo "Missing Info.plist: $info_plist" >&2; exit 1; }
if [[ -n "$sparkle_framework" ]]; then
  [[ -d "$sparkle_framework" ]] || { echo "Missing Sparkle.framework: $sparkle_framework" >&2; exit 1; }
fi
if [[ -n "$entitlements_path" ]]; then
  [[ -f "$entitlements_path" ]] || { echo "Missing entitlements: $entitlements_path" >&2; exit 1; }
fi

bundle_executable="$(plutil -extract CFBundleExecutable raw "$info_plist")"
macos_dir="$output_app/Contents/MacOS"
resources_dir="$output_app/Contents/Resources"
frameworks_dir="$output_app/Contents/Frameworks"

rm -rf "$output_app"
mkdir -p "$macos_dir" "$resources_dir" "$frameworks_dir"

cp "$binary_path" "$macos_dir/$bundle_executable"
chmod +x "$macos_dir/$bundle_executable"
cp -R "$resources_bundle" "$resources_dir/"
cp "$info_plist" "$output_app/Contents/Info.plist"

if [[ -f "$resources_bundle/AppIcon.icns" ]]; then
  cp "$resources_bundle/AppIcon.icns" "$resources_dir/AppIcon.icns"
fi
if [[ -f "$resources_bundle/ClaudeUsage.sdef" ]]; then
  cp "$resources_bundle/ClaudeUsage.sdef" "$resources_dir/ClaudeUsage.sdef"
fi
if [[ -n "$sparkle_framework" ]]; then
  cp -R "$sparkle_framework" "$frameworks_dir/"
fi

if command -v otool >/dev/null 2>&1; then
  if ! otool -l "$macos_dir/$bundle_executable" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$macos_dir/$bundle_executable"
  fi
fi

if [[ "$should_sign" -eq 1 ]] && command -v codesign >/dev/null 2>&1; then
  codesign_args=(--force --deep --sign "$codesign_identity")
  if [[ "$codesign_identity" == "-" ]]; then
    codesign_args+=(--timestamp=none)
  else
    codesign_args+=(--options runtime --timestamp)
    if [[ -n "$entitlements_path" ]]; then
      codesign_args+=(--entitlements "$entitlements_path")
    fi
  fi
  codesign "${codesign_args[@]}" "$output_app"
fi

echo "Bundled $output_app"
