#!/usr/bin/env python3
"""Generate Log Highlight tmLanguage/tmTheme from Log Highlight.sublime-settings (stdlib only)."""
import json
import re
import sys
from pathlib import Path


def gen_loghighlight_syntax(settings_dir: Path, lh_settings_src: Path) -> None:
    if not lh_settings_src.exists():
        return

    LINK_REGX_PLIST = r"""["']?[\w\d\:\\\/\.\-\=]+\.\w+[\w\d]*["']?\s*[,:on line\(]{1,9}\s*\d+\)?\:?(\d+)?"""
    LINK_REGX_SETTING = r"""(["']?[\w\d\:\\\/\.\-\=]+\.\w+[\w\d]*["']?\s*[,:on line\(]{1,9}\s*\d+\)?\:?(\d+)?)"""
    QUOTE_REGX_PLIST = r"""(["'])(?:(?=(\\?))\2.)*?\1"""
    QUOTE_REGX_SETTING = r"""(["'].+?["'])"""

    def _conv_plist(s):
        return s.replace("<", "&lt;").replace(">", "&gt;")

    def _conv_regx(s):
        return s.replace("{{{LINK}}}", LINK_REGX_SETTING).replace("{{{QUOTE}}}", QUOTE_REGX_SETTING)

    def _sub_capture(regx, severity, sel):
        spw = re.findall(r"\{\{\{LINK\}\}\}|\{\{\{QUOTE\}\}\}", regx)
        if not spw:
            return ""
        tag = {0: "beginCaptures", 1: "endCaptures", 2: "captures"}[sel]
        ret = f'\n            <key>{tag}</key>\n            <dict>'
        for i, w in enumerate(spw):
            lqs = "link" if w == "{{{LINK}}}" else "quote"
            ret += (
                f'\n                <key>{i + 1}</key>\n                <dict>'
                f'\n                    <key>name</key>'
                f'\n                    <string>msg.{severity}.{lqs}</string>'
                f"\n                </dict>"
            )
        return ret + "\n            </dict>"

    try:
        raw = re.sub(r"//[^\n]*", "", lh_settings_src.read_text(encoding="utf-8"))
        cfg = json.loads(raw)
    except Exception:
        return

    for log_name, log_cfg in cfg.get("log_list", {}).items():
        svt = log_cfg.get("severity", {})
        svl = [k for k in svt if svt[k].get("enable", False)]
        theme_cfg = log_cfg.get("theme", {})
        out_dir = settings_dir / "Log Highlight"
        out_dir.mkdir(parents=True, exist_ok=True)

        sub_pat = ""
        sub_lq = ""
        for k in svl:
            for p in svt[k].get("pattern", []):
                p0, p1 = _conv_plist(p[0]), _conv_plist(p[1])
                r0, r1 = _conv_regx(p0), _conv_regx(p1)
                if p1:
                    sub_pat += (
                        f"\n        <dict>"
                        f'\n            <key>begin</key><string>{r0}</string>{_sub_capture(p[0], k, 0)}'
                        f'\n            <key>end</key><string>{r1}</string>{_sub_capture(p[1], k, 1)}'
                        f'\n            <key>name</key><string>msg.{k}</string>'
                        f"\n            <key>patterns</key><array>"
                        f'\n                <dict><key>include</key><string>#{k}_link</string></dict>'
                        f'\n                <dict><key>include</key><string>#{k}_quote</string></dict>'
                        f"\n            </array>\n        </dict>"
                    )
                else:
                    sub_pat += (
                        f"\n        <dict>"
                        f'\n            <key>match</key><string>{r0}</string>{_sub_capture(p[0], k, 2)}'
                        f'\n            <key>name</key><string>msg.{k}</string>'
                        f"\n            <key>patterns</key><array>"
                        f'\n                <dict><key>include</key><string>#{k}_link</string></dict>'
                        f'\n                <dict><key>include</key><string>#{k}_quote</string></dict>'
                        f"\n            </array>\n        </dict>"
                    )
            sub_lq += (
                f"\n        <key>{k}_link</key><dict>"
                f"\n            <key>match</key><string>{LINK_REGX_PLIST}</string>"
                f'\n            <key>name</key><string>msg.{k}.link</string></dict>'
                f"\n        <key>{k}_quote</key><dict>"
                f"\n            <key>match</key><string>{QUOTE_REGX_PLIST}</string>"
                f'\n            <key>name</key><string>msg.{k}.quote</string></dict>'
            )

        tmlang = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
            f'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            f'<plist version="1.0">\n<dict>\n'
            f"    <key>fileTypes</key><array/>\n"
            f'    <key>name</key><string>Log Highlight - {log_name}</string>\n'
            f"    <key>patterns</key><array>{sub_pat}\n    </array>\n"
            f"    <key>repository</key><dict>{sub_lq}\n    </dict>\n"
            f'    <key>scopeName</key><string>source.loghighlight.{log_name}</string>\n'
            f'    <key>uuid</key><string>0ed2482c-a94a-49dc-9aae-b1401bcff2e0</string>\n'
            f"</dict>\n</plist>\n"
        )

        sub_theme = ""
        for k in svl:
            for c, v in svt[k].get("color", {}).items():
                p = "" if c == "base" else "." + c
                fg = (
                    f'\n                <key>foreground</key><string>{v[0]}</string>'
                    if isinstance(v, list)
                    else f"<key>foreground</key><string>{v}</string>"
                )
                bg = (
                    f'\n                <key>background</key><string>{v[1]}</string>'
                    if isinstance(v, list) and v[1]
                    else ""
                )
                sub_theme += (
                    f"\n        <dict>"
                    f'\n            <key>scope</key><string>msg.{k}{p}</string>'
                    f"\n            <key>settings</key><dict>{fg}{bg}\n            </dict>"
                    f"\n        </dict>"
                )

        bgclr = "#1E1E2E"
        tmtheme = (
            f'<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<!DOCTYPE plist PUBLIC "-//Apple //DTD PLIST 1.0//EN" '
            f'"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
            f'<plist version="1.0">\n<dict>\n'
            f'    <key>name</key><string>Log Highlight - {log_name}</string>\n'
            f"    <key>settings</key>\n    <array>\n        <dict>\n"
            f"            <key>settings</key>\n            <dict>\n"
            f'                <key>background</key><string>{bgclr}</string>\n'
            f'                <key>caret</key><string>{theme_cfg.get("caret", "#F29718")}</string>\n'
            f'                <key>foreground</key><string>{theme_cfg.get("foreground", "#D7D7D7")}</string>\n'
            f'                <key>lineHighlight</key><string>{theme_cfg.get("lineHighlight", "#283240")}</string>\n'
            f'                <key>selection</key><string>{theme_cfg.get("selection", "#3A5166")}</string>\n'
            f'                <key>selectionBorder</key><string>{theme_cfg.get("selectionBorder", "#181E26")}</string>\n'
            f"            </dict>\n        </dict>{sub_theme}\n    </array>\n"
            f'    <key>uuid</key><string>403e2150-aad4-41ff-86d0-36d87510918e</string>\n'
            f"</dict>\n</plist>\n"
        )

        (out_dir / f"{log_name}-log.tmLanguage").write_text(tmlang, encoding="utf-8")
        (out_dir / f"{log_name}-log.tmTheme").write_text(tmtheme, encoding="utf-8")
        print(f"Sublime: Log Highlight syntax/theme generated for '{log_name}'")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <sublime_packages_user_dir> <log_highlight.sublime-settings>", file=sys.stderr)
        sys.exit(1)
    gen_loghighlight_syntax(Path(sys.argv[1]), Path(sys.argv[2]))
