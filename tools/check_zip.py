#!/usr/bin/env python3
"""Check a release zip: py tools/check_zip.py dist/<zip>. Exits non-zero if anything expected is missing
or something that should never ship (config, logs, agent notes, personal paths) is present."""
import re
import sys
import zipfile

REQUIRED = [
    "scripts/twitch-rewind/main.lua", "scripts/twitch-rewind/README.md", "scripts/twitch-rewind/LICENSE",
    "scripts/clipper/main.lua", "scripts/clipper/editor.lua", "scripts/clipper/worker.py",
    "scripts/clipper/advice.lua", "scripts/clipper/integrate.py", "scripts/clipper/live.py",
    "scripts/clipper/README.md", "scripts/clipper/LICENSE",
    "scripts/modernz.lua", "scripts/modernz-LICENSE.txt",
    "fonts/modernz-icons.ttf", "fonts/Material-Design-Iconic-Font.ttf", "fonts/Material-Design-Iconic-Font-OFL.txt",
    "script-opts/twitch-rewind.conf.example", "script-opts/clipper.conf.example",
    "INSTALL-twitch-rewind-clipper.txt",
]
FORBIDDEN_NAMES = re.compile(r"(^|/)(mpv\.conf|input\.conf|.*cookies.*|.*\.log|HANDOFF.*|AGENTS\.md|CLAUDE\.md|design-spec\.md|\.test/.*)$", re.I)
FORBIDDEN_TEXT = re.compile(r"C:[/\\]Users|AppData[/\\]Roaming[/\\]mpv[/\\](?!scripts)|S:[/\\]Clips|twitch[-_]dvr|clip[-_]window", re.I)
TEXT_EXT = (".lua", ".py", ".md", ".txt", ".conf", ".example")
# these detect controllers that were patched under the plugin's old name, on purpose
LEGACY_MARKER_FILES = ("scripts/clipper/main.lua", "scripts/clipper/integrate.py")


def main(path):
    problems = []
    with zipfile.ZipFile(path) as z:
        names = z.namelist()
        problems += [f"missing: {n}" for n in REQUIRED if n not in names]
        for n in names:
            if FORBIDDEN_NAMES.search(n):
                problems.append(f"must not ship: {n}")
            if not n.endswith(TEXT_EXT):
                continue
            if n == "scripts/modernz.lua":   # upstream code, scanned for names it never had
                continue
            legacy_ok = n in LEGACY_MARKER_FILES
            for number, line in enumerate(z.read(n).decode("utf-8", "ignore").splitlines(), 1):
                if FORBIDDEN_TEXT.search(line) and not (legacy_ok and "clip-window" in line):
                    problems.append(f"{n}:{number}: {line.strip()[:100]}")
    for p in problems:
        print(p)
    print(f"{path}: {len(names)} files, {'OK' if not problems else str(len(problems)) + ' problem(s)'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
