"""Add a Clip button to the modernz or ModernX on-screen controller.

Usage: integrate.py <path to modernz.lua or modernx.lua>

Running it again is harmless. Every anchor is checked before anything is
written, and the original file is kept in clipper/backup/.
"""
import os
from pathlib import Path
import re
import sys

MARK = "clipper"
LEGACY_MARK = "clip-window"   # the name this plugin had; controllers patched back then count as integrated
HERE = Path(__file__).resolve().parent


def icon():
    """A scissors glyph that matches the controller's fluent icons where possible."""
    fonts = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts"
    for file, family in (("SegoeIcons.ttf", "Segoe Fluent Icons"), ("segmdl2.ttf", "Segoe MDL2 Assets")):
        if os.name == "nt" and (fonts / file).is_file():
            return '"{\\\\fn%s}\\238\\163\\134"' % family  # U+E8C6, Cut
    return '"\\226\\156\\130"'  # U+2702 in the controller's text font


def modernz(text, content):
    edits = [
        (r"^([ \t]*)screenshot_button\s*=.*\n",
         lambda m: m[0] + f'{m[1]}clip_button = true,                     -- show Clip button ({MARK})\n'),
        (r"^([ \t]*)screenshot_mbtn_left_command\s*=.*\n",
         lambda m: m[0] + f'{m[1]}clip_mbtn_left_command = "script-binding clipper/open",       -- {MARK}\n'
                          f'{m[1]}clip_mbtn_right_command = "script-binding clipper/open-live",  -- {MARK}\n'),
        (r'^([ \t]*)bind_buttons\("screenshot"\)\n',
         lambda m: m[0] + f'\n{m[1]}-- clip ({MARK})\n{m[1]}ne = new_element("clip", "button")\n'
                          f'{m[1]}ne.content = {content}\n{m[1]}ne.tooltipF = "Clip"\n{m[1]}bind_buttons("clip")\n'),
        # Every layout that offers a screenshot button gets the Clip button beside it.
        (r'^([ \t]*)right_side_button\("screenshot", (\d+), user_opts\.screenshot_button\)\n',
         lambda m: m[0] + f'{m[1]}right_side_button("clip", {m[2]}, user_opts.clip_button)  -- {MARK}\n'),
    ]
    return apply(text, edits)


def modernx(text, content):
    edits = [
        (r"^([ \t]*)lo = add_layout\('tog_info'\)\n(?:.*\n){3}",
         lambda m: m[0] + f"    lo = add_layout('clip')  -- {MARK}\n"
                          "    lo.geometry = {x = osc_geo.w - 137, y = refY - 40, an = 5, w = 24, h = 24}\n"
                          "    lo.style = osc_styles.Ctrl3\n"
                          "    lo.visible = (osc_param.playresx >= 650)\n"),
        (r"^([ \t]*)ne = new_element\('tog_info', 'button'\)\n(?:.*\n){4}",
         lambda m: m[0] + f"\n    -- clip ({MARK})\n    ne = new_element('clip', 'button')\n"
                          f"    ne.content = {content}\n    ne.visible = (osc_param.playresx >= 650)\n"
                          "    ne.eventresponder['mbtn_left_up'] =\n"
                          "        function () mp.commandv('script-binding', 'clipper/open') end\n"
                          "    ne.eventresponder['mbtn_right_up'] =\n"
                          "        function () mp.commandv('script-binding', 'clipper/open-live') end\n"),
    ]
    return apply(text, edits)


def apply(text, edits):
    for pattern, insert in edits:
        text, count = re.subn(pattern, insert, text, flags=re.M)
        if not count:
            raise RuntimeError(f"Unrecognised controller version: no match for {pattern!r}. Nothing was changed.")
    return text


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    target = Path(sys.argv[1])
    raw = target.read_bytes()
    text = raw.decode("utf-8")
    if MARK in text or LEGACY_MARK in text:
        print("already integrated")
        return
    newline = "\r\n" if "\r\n" in text else "\n"
    text = text.replace("\r\n", "\n")
    name = target.stem.lower()
    if name == "modernz":
        patched = modernz(text, icon())
    elif name == "modernx":
        patched = modernx(text, icon())
    else:
        raise RuntimeError(f"{target.name} is not modernz.lua or modernx.lua")
    backup = HERE / "backup" / target.name
    backup.parent.mkdir(exist_ok=True)
    backup.write_bytes(raw)
    staged = target.with_name("." + target.name + ".tmp")
    staged.write_bytes(patched.replace("\n", newline).encode("utf-8"))
    os.replace(staged, target)
    print(f"added Clip button; original saved to {backup}")


if __name__ == "__main__":
    main()
