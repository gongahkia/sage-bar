#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
from shutil import which
from subprocess import run
from urllib.request import Request, urlopen

from diagrams import Cluster, Diagram, Edge
from diagrams.custom import Custom
from diagrams.generic.storage import Storage
from diagrams.onprem.ci import GithubActions
from diagrams.onprem.client import User
from diagrams.programming.language import Swift


ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = ROOT / "asset" / "reference"
ICON_DIR = ASSET_DIR / "icons"
OUTPUT_BASE = ASSET_DIR / "architecture"

ICON_SOURCES = {
    "apple": "https://cdn.simpleicons.org/apple",
    "anthropic": "https://cdn.simpleicons.org/anthropic",
    "githubcopilot": "https://cdn.simpleicons.org/githubcopilot",
    "googlegemini": "https://cdn.simpleicons.org/googlegemini",
    "homebrew": "https://cdn.simpleicons.org/homebrew",
    "icloud": "https://cdn.simpleicons.org/icloud",
    "make": "https://cdn.simpleicons.org/make",
    "openai": "https://raw.githubusercontent.com/gilbarbara/logos/main/logos/openai-icon.svg",
    "toml": "https://cdn.simpleicons.org/toml",
    "windsurf": "https://cdn.simpleicons.org/windsurf",
}

ICON_SIZE_PX = 256

SPARKLE_SVG = """\
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128">
  <g fill="none" fill-rule="evenodd">
    <path fill="#F59E0B" d="M64 10l10 29 29 10-29 10-10 29-10-29-29-10 29-10z"/>
    <path fill="#FBBF24" d="M95 18l4 12 12 4-12 4-4 12-4-12-12-4 12-4z"/>
    <path fill="#FDE68A" d="M28 76l5 15 15 5-15 5-5 15-5-15-15-5 15-5z"/>
  </g>
</svg>
"""


def request_headers() -> dict[str, str]:
    return {
        "User-Agent": "Mozilla/5.0 (compatible; SageBarArchitecture/1.0)",
        "Accept": "image/svg+xml,image/*;q=0.8,*/*;q=0.5",
    }


def ensure_svg_icon(name: str) -> Path:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    icon_path = ICON_DIR / f"{name}.svg"
    if icon_path.exists():
        return icon_path

    if name == "sparkle":
        icon_path.write_text(SPARKLE_SVG, encoding="utf-8")
        return icon_path

    url = ICON_SOURCES[name]
    request = Request(url, headers=request_headers())
    with urlopen(request, timeout=30) as response:
        icon_path.write_bytes(response.read())
    return icon_path


def ensure_png_icon(name: str) -> Path:
    svg_path = ensure_svg_icon(name)
    png_path = ICON_DIR / f"{name}.png"
    if png_path.exists() and png_path.stat().st_mtime >= svg_path.stat().st_mtime:
        return png_path

    converter = which("rsvg-convert")
    if converter is None:
        return svg_path

    run(
        [
            converter,
            "-f",
            "png",
            "-w",
            str(ICON_SIZE_PX),
            "-h",
            str(ICON_SIZE_PX),
            "-o",
            str(png_path),
            str(svg_path),
        ],
        check=True,
    )
    return png_path


def branded(label: str, icon_name: str) -> Custom:
    return Custom(label, str(ensure_png_icon(icon_name)))


def cluster_style(fill: str, rankdir: str = "LR") -> dict[str, str]:
    return {
        "bgcolor": fill,
        "color": "#CBD5E1",
        "pencolor": "#CBD5E1",
        "fontname": "Helvetica-Bold",
        "fontsize": "16",
        "fontcolor": "#0F172A",
        "margin": "18",
        "style": "rounded",
        "rankdir": rankdir,
    }


def main() -> None:
    ASSET_DIR.mkdir(parents=True, exist_ok=True)

    graph_attr = {
        "bgcolor": "white",
        "pad": "0.35",
        "nodesep": "0.55",
        "ranksep": "0.9",
        "splines": "spline",
        "fontname": "Helvetica",
        "fontsize": "20",
        "fontcolor": "#0F172A",
        "labeljust": "l",
        "labelloc": "t",
        "dpi": "220",
    }
    node_attr = {
        "fontname": "Helvetica",
        "fontsize": "11",
        "fontcolor": "#111827",
        "color": "#CBD5E1",
        "style": "rounded,filled",
        "fillcolor": "#FFFFFF",
        "labelloc": "b",
        "imagescale": "true",
        "margin": "0.15,0.10",
    }
    edge_attr = {
        "color": "#64748B",
        "penwidth": "1.5",
        "fontname": "Helvetica",
        "fontsize": "10",
        "fontcolor": "#334155",
    }

    with Diagram(
        "Sage Bar Architecture",
        filename=str(OUTPUT_BASE),
        outformat="png",
        show=False,
        direction="LR",
        graph_attr=graph_attr,
        node_attr=node_attr,
        edge_attr=edge_attr,
    ):
        user = User("macOS user")

        with Cluster("Build & Delivery", graph_attr=cluster_style("#EFF6FF")):
            swiftpm = Swift("Swift 6.2 + SwiftPM\nsingle executable target")
            packaging = branded("Makefile + bundle scripts\ncodesign / verify / archive", "make")
            ci = GithubActions("GitHub Actions\nSwiftLint / swift-format /\nswift test / release")
            sparkle = branded("Sparkle updater\nGitHub Pages appcast", "sparkle")
            homebrew = branded("Homebrew\ncask + formula", "homebrew")
            swiftpm >> Edge(style="invis") >> packaging >> Edge(style="invis") >> ci
            ci >> Edge(style="invis") >> sparkle >> Edge(style="invis") >> homebrew

        with Cluster("Local Providers", graph_attr=cluster_style("#FFF7ED")):
            claude_logs = branded("Claude Code logs\n~/.claude/projects/*.jsonl", "anthropic")
            codex_logs = branded("Codex logs\n~/.codex/sessions/*.jsonl", "openai")
            gemini_logs = branded("Gemini CLI chats\n~/.gemini/tmp/**/chats/*.json", "googlegemini")
            claude_logs >> Edge(style="invis") >> codex_logs >> Edge(style="invis") >> gemini_logs

        with Cluster("Remote Providers", graph_attr=cluster_style("#FDF2F8")):
            anthropic_api = branded("Anthropic Usage API", "anthropic")
            openai_api = branded("OpenAI org usage + costs APIs", "openai")
            copilot_api = branded("GitHub Copilot metrics API", "githubcopilot")
            windsurf_api = branded("Windsurf Enterprise APIs", "windsurf")
            claude_ai_api = branded("claude.ai /api/usage", "anthropic")
            anthropic_api >> Edge(style="invis") >> openai_api >> Edge(style="invis") >> copilot_api
            copilot_api >> Edge(style="invis") >> windsurf_api >> Edge(style="invis") >> claude_ai_api

        with Cluster("Sage Bar Runtime", graph_attr=cluster_style("#F5F3FF")):
            app_shell = branded(
                "Sage Bar accessory app\nSwiftUI + AppKit\nmenu bar / settings / onboarding",
                "apple",
            )
            local_ingest = Swift(
                "Parser watchers\nClaudeCodeLogParser\nCodexLogParser\nGeminiLogParser"
            )
            remote_ingest = Swift(
                "Remote clients\nAnthropic / OpenAI /\nGitHub / Windsurf / ClaudeAI"
            )
            polling = Swift(
                "PollingService +\nPollingOrchestrator\ncadence / retry / circuit breaker"
            )
            domain = Swift(
                "CacheManager actor\nForecastEngine / AnalyticsEngine /\nModelOptimizerAnalyzer"
            )
            outputs = branded(
                "Outputs & automations\nNotifications / webhooks / App Intents /\nAppleScript / CSV / hotkeys / iCloud sync",
                "apple",
            )
            app_shell >> Edge(style="invis") >> local_ingest >> Edge(style="invis") >> remote_ingest
            remote_ingest >> Edge(style="invis") >> polling >> Edge(style="invis") >> domain >> Edge(style="invis") >> outputs

        with Cluster("Config & Persistence", graph_attr=cluster_style("#ECFDF5")):
            config = branded(
                "ConfigManager + TOMLKit\n~/.config/claude-usage/config.toml",
                "toml",
            )
            keychain = branded("macOS Keychain\nAPI keys / session tokens", "apple")
            cache = Storage(
                "App Group container\nusage_cache.json / forecasts /\ncheckpoints / parser metrics"
            )
            defaults = Storage("UserDefaults\nselection / cooldowns / sync metadata")
            icloud = branded("Optional iCloud sync\nusage_cache mirror", "icloud")
            config >> Edge(style="invis") >> keychain >> Edge(style="invis") >> cache
            cache >> Edge(style="invis") >> defaults >> Edge(style="invis") >> icloud

        user >> Edge(color="#2563EB") >> app_shell

        swiftpm >> Edge(style="dashed", color="#2563EB") >> app_shell
        packaging >> Edge(style="dashed", color="#2563EB") >> app_shell
        ci >> Edge(style="dashed", color="#2563EB") >> app_shell
        sparkle >> Edge(style="dashed", color="#2563EB", label="updates") >> app_shell
        homebrew >> Edge(style="dashed", color="#2563EB") >> app_shell

        claude_logs >> Edge(label="FSEvents + checkpoints") >> local_ingest
        codex_logs >> Edge(label="incremental JSONL parsing") >> local_ingest
        gemini_logs >> Edge(label="chat JSON parsing") >> local_ingest

        anthropic_api >> remote_ingest
        openai_api >> remote_ingest
        copilot_api >> remote_ingest
        windsurf_api >> remote_ingest
        claude_ai_api >> remote_ingest

        config >> app_shell
        config >> polling
        keychain >> Edge(label="credentials") >> remote_ingest
        defaults >> app_shell
        defaults >> outputs

        app_shell >> Edge(label="launch bootstraps polling") >> polling
        local_ingest >> Edge(label="local snapshots") >> polling
        remote_ingest >> Edge(label="provider fetches") >> polling

        polling >> Edge(label="persist + derive state") >> domain
        domain >> Edge(label="write/read JSON state") >> cache
        cache >> Edge(label="render from cache") >> app_shell
        domain >> Edge(label="forecasts / trends / hints") >> app_shell

        polling >> Edge(label="thresholds / burn rate / automations") >> outputs
        cache >> Edge(label="summaries / exports / scripting") >> outputs

        cache >> Edge(color="#0EA5E9", style="dashed") >> icloud
        icloud >> Edge(color="#0EA5E9", style="dashed", label="merge on syncNow") >> domain


if __name__ == "__main__":
    main()
