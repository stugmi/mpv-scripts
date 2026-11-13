#!/usr/bin/env python3
"""Install the plugins in this repo into an mpv config folder.

    py tools/install.py                 # into %APPDATA%\\mpv
    py tools/install.py --target D:\\portable_mpv\\portable_config
    py tools/install.py --dry-run

Copies twitch-rewind, clipper and the patched ModernZ over the installed versions. An installed
modernz.lua that differs is kept as modernz.lua.bak first. Config files (script-opts/*.conf, mpv.conf)
are never overwritten. The plugins used to be called twitch-dvr and clip-window: those installed
folders are removed (mpv would load both generations) and an existing twitch-dvr.conf / clip-window.conf
is renamed to the new name. Close mpv before running so no file is locked.
"""
import argparse
import os
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLUGINS = ROOT / "plugins"

# plugin folder name == script folder name == script-opts name
SCRIPT_PLUGINS = ["twitch-rewind", "clipper"]
# single files: (source, destination relative to the mpv folder)
FILES = [
    (PLUGINS / "ModernZ" / "modernz.lua", "scripts/modernz.lua"),
    (PLUGINS / "ModernZ" / "modernz-icons.ttf", "fonts/modernz-icons.ttf"),
]
# name before the rename -> name now
LEGACY = {"twitch-dvr": "twitch-rewind", "clip-window": "clipper"}


def collect():
    """Every (source, relative destination) pair this repo installs."""
    pairs = []
    for name in SCRIPT_PLUGINS:
        plugin = PLUGINS / name
        script_dir = plugin / "scripts" / name
        for src in sorted(p for p in script_dir.iterdir() if p.is_file()):
            pairs.append((src, f"scripts/{name}/{src.name}"))
        pairs.append((plugin / "README.md", f"scripts/{name}/README.md"))
    pairs.extend(FILES)
    missing = [str(src) for src, _ in pairs if not src.is_file()]
    if missing:
        sys.exit("Missing source files:\n  " + "\n  ".join(missing))
    return pairs


def sample_configs():
    """(source, name) of each plugin's sample config; the name is what it is called in script-opts."""
    return [(PLUGINS / n / "script-opts" / f"{n}.conf", f"{n}.conf") for n in SCRIPT_PLUGINS]


def default_target():
    if os.name == "nt":
        return Path(os.environ["APPDATA"]) / "mpv"
    return Path.home() / ".config" / "mpv"


def same(a: Path, b: Path):
    return b.is_file() and a.stat().st_size == b.stat().st_size and a.read_bytes() == b.read_bytes()


def migrate_legacy(target: Path, dry_run: bool):
    """Move the old-named plugins out of the way. Returns how many things changed."""
    changed = 0
    for old, new in LEGACY.items():
        old_dir = target / "scripts" / old
        if old_dir.is_dir():
            changed += 1
            print(f"remove scripts/{old}/   (replaced by scripts/{new}/)")
            backup = old_dir / "backup"      # clipper's saved original controller, if any
            if not dry_run:
                if backup.is_dir():
                    (target / "scripts" / new).mkdir(parents=True, exist_ok=True)
                    shutil.copytree(backup, target / "scripts" / new / "backup", dirs_exist_ok=True)
                shutil.rmtree(old_dir)
        old_conf, new_conf = target / "script-opts" / f"{old}.conf", target / "script-opts" / f"{new}.conf"
        if old_conf.is_file():
            changed += 1
            if new_conf.exists():
                print(f"keep   script-opts/{old}.conf   (script-opts/{new}.conf already exists; merge by hand)")
            else:
                print(f"rename script-opts/{old}.conf -> {new}.conf")
                if not dry_run:
                    old_conf.rename(new_conf)
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--target", type=Path, default=default_target(), help="mpv config folder (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true", help="show what would change without writing")
    args = parser.parse_args()

    target = args.target
    if not target.is_dir():
        sys.exit(f"mpv folder not found: {target}")

    changed = migrate_legacy(target, args.dry_run)
    for src, rel in collect():
        dest = target / rel
        if same(src, dest):
            continue
        changed += 1
        verb = "update" if dest.exists() else "add   "
        print(f"{verb} {rel}")
        if args.dry_run:
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        if dest.name == "modernz.lua" and dest.exists():
            shutil.copy2(dest, dest.with_name("modernz.lua.bak"))
        shutil.copy2(src, dest)
    print(f"{changed} change(s) {'pending' if args.dry_run else 'made'}. Restart mpv to load them." if changed
          else "Already up to date.")


if __name__ == "__main__":
    main()
