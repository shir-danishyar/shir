#!/usr/bin/env python3
"""Extract scriptlet bodies from Brave's adblock resource bundle.

Shir does not embed Brave's Rust engine — see CLAUDE.md §3. The engine's job at
runtime is to pick which scriptlets match a hostname, decode them, substitute
arguments, and concatenate. For one hostname we target permanently, that is a
build-time operation, and this script is it.

`brave-resources.json` is a flat JSON array of {name, aliases, kind, content}
where `content` is base64. No Rust toolchain required.

Usage:
    scripts/extract-brave-scriptlets.py --list
    scripts/extract-brave-scriptlets.py brave-video-bg-play-update.js
    scripts/extract-brave-scriptlets.py --out vendor/ brave-yt-sabr-fix.js

Re-run against a newer bundle when YouTube breaks things. Record provenance and
licence in a comment wherever the output gets adapted — the bg-play scriptlets
are MIT (from mozilla/video-bg-play), the uBO ones are GPL-3.0.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

DEFAULT_BUNDLE = (
    Path(__file__).resolve().parent.parent.parent
    / "youtube-clons"
    / "adblock-rust"
    / "data"
    / "brave"
    / "brave-resources.json"
)


def load_bundle(path: Path) -> dict[str, dict]:
    if not path.exists():
        sys.exit(
            f"resource bundle not found: {path}\n"
            "Pass --bundle, or clone brave/adblock-rust next to this project."
        )
    with path.open(encoding="utf-8") as fh:
        return {entry["name"]: entry for entry in json.load(fh)}


def decode(entry: dict) -> str:
    return base64.b64decode(entry["content"]).decode("utf-8", "replace")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("names", nargs="*", help="scriptlet names, e.g. brave-fix.js")
    parser.add_argument("--bundle", type=Path, default=DEFAULT_BUNDLE)
    parser.add_argument("--list", action="store_true", help="list available names")
    parser.add_argument("--filter", default="", help="substring filter for --list")
    parser.add_argument("--out", type=Path, help="write each body to this directory")
    args = parser.parse_args()

    by_name = load_bundle(args.bundle)

    if args.list:
        for name in sorted(by_name):
            if args.filter in name:
                print(name)
        return 0

    if not args.names:
        parser.error("give at least one scriptlet name, or use --list")

    missing = [n for n in args.names if n not in by_name]
    for name in missing:
        print(f"NOT FOUND: {name}", file=sys.stderr)

    for name in args.names:
        entry = by_name.get(name)
        if entry is None:
            continue
        body = decode(entry)

        if args.out:
            args.out.mkdir(parents=True, exist_ok=True)
            target = args.out / name
            target.write_text(body, encoding="utf-8")
            print(f"wrote {target} ({len(body)} bytes)")
            continue

        print("=" * 70)
        print(f"### {name}")
        print(f"    aliases      : {entry.get('aliases', [])}")
        print(f"    dependencies : {entry.get('dependencies', [])}")
        print(f"    bytes        : {len(body)}")
        print("=" * 70)
        print(body)

    return 1 if missing else 0


if __name__ == "__main__":
    raise SystemExit(main())
