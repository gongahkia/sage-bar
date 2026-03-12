#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


DIFF_HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
FORMAT_RE = re.compile(r"^(.*?):(\d+):(\d+): (warning|error): (.*)$")


def repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        check=True,
        capture_output=True,
        text=True,
    )
    return Path(result.stdout.strip())


def changed_lines(base: str, head: str) -> dict[str, set[int]]:
    result = subprocess.run(
        ["git", "diff", "--unified=0", base, head, "--", "*.swift"],
        check=True,
        capture_output=True,
        text=True,
    )
    lines_by_file: dict[str, set[int]] = defaultdict(set)
    current_file: str | None = None

    for line in result.stdout.splitlines():
        if line.startswith("+++ b/"):
            current_file = line[6:]
            continue
        if line.startswith("+++ /dev/null"):
            current_file = None
            continue
        if not current_file:
            continue
        match = DIFF_HUNK_RE.match(line)
        if not match:
            continue
        start = int(match.group(1))
        count = int(match.group(2) or "1")
        if count <= 0:
            continue
        lines_by_file[current_file].update(range(start, start + count))

    return lines_by_file


def normalize_path(path_text: str, root: Path) -> str:
    path = Path(path_text)
    if path.is_absolute():
        try:
            return str(path.relative_to(root))
        except ValueError:
            return str(path)
    return str(path)


def filter_swiftlint_json(raw: str, line_map: dict[str, set[int]], root: Path) -> list[str]:
    raw = raw.strip()
    if not raw:
        return []

    try:
        diagnostics = json.loads(raw)
    except json.JSONDecodeError:
        return [raw]

    filtered: list[str] = []
    for diagnostic in diagnostics:
        file_path = normalize_path(str(diagnostic.get("file", "")), root)
        line = int(diagnostic.get("line", 0) or 0)
        if line not in line_map.get(file_path, set()):
            continue
        rule = diagnostic.get("rule_id", "swiftlint")
        reason = diagnostic.get("reason", "").strip()
        filtered.append(f"{file_path}:{line}: {reason} ({rule})")

    return filtered


def filter_swift_format(raw: str, line_map: dict[str, set[int]], root: Path) -> list[str]:
    filtered: list[str] = []
    for line in raw.splitlines():
        if not line.strip():
            continue
        match = FORMAT_RE.match(line)
        if not match:
            filtered.append(line)
            continue
        file_path = normalize_path(match.group(1), root)
        line_number = int(match.group(2))
        if line_number not in line_map.get(file_path, set()):
            continue
        filtered.append(
            f"{file_path}:{line_number}:{match.group(3)}: {match.group(4)}: {match.group(5)}"
        )
    return filtered


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["swiftlint-json", "swift-format"])
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    args = parser.parse_args()

    root = repo_root()
    line_map = changed_lines(args.base, args.head)
    raw = sys.stdin.read()

    if args.mode == "swiftlint-json":
        filtered = filter_swiftlint_json(raw, line_map, root)
    else:
        filtered = filter_swift_format(raw, line_map, root)

    if not filtered:
        return 0

    sys.stdout.write("\n".join(filtered) + "\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
