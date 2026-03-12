#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify_app_bundle.sh --app PATH [options]

Options:
  --app PATH         .app bundle to verify
  --skip-spctl       Skip spctl assessment
  --smoke-launch     Launch the app with open -n and require the process to stay alive briefly
  --launch-wait N    Seconds to wait during smoke launch (default: 6)
EOF
}

app_path=""
skip_spctl=0
smoke_launch=0
launch_wait=6

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      app_path="$2"
      shift 2
      ;;
    --skip-spctl)
      skip_spctl=1
      shift
      ;;
    --smoke-launch)
      smoke_launch=1
      shift
      ;;
    --launch-wait)
      launch_wait="$2"
      shift 2
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

[[ -d "$app_path" ]] || { echo "Missing app bundle: $app_path" >&2; exit 1; }

info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || { echo "Missing Info.plist in bundle" >&2; exit 1; }

bundle_executable="$(plutil -extract CFBundleExecutable raw "$info_plist")"
executable_path="$app_path/Contents/MacOS/$bundle_executable"
[[ -x "$executable_path" ]] || { echo "Missing executable in bundle: $executable_path" >&2; exit 1; }

codesign --verify --deep --strict "$app_path"

if [[ "$skip_spctl" -eq 0 ]]; then
  spctl --assess --type execute --verbose=4 "$app_path"
fi

if [[ "$smoke_launch" -eq 1 ]]; then
  open -n "$app_path"
  sleep "$launch_wait"
  if ! pgrep -x "$bundle_executable" >/dev/null 2>&1; then
    echo "Smoke launch failed: $bundle_executable did not stay alive" >&2
    exit 1
  fi
  pkill -x "$bundle_executable" || true
fi

echo "Verified $app_path"
