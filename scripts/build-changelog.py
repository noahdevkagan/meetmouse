#!/usr/bin/env python3
"""Render CHANGELOG.md into docs/changelog.html (and localized copies) for meetmouse.com.

The page is a pure function of CHANGELOG.md so the two can never drift:
the push gate regenerates it and fails if the committed copy is stale.

    python3 scripts/build-changelog.py          # write docs/changelog.html & localized copies
    python3 scripts/build-changelog.py --check  # exit 1 if any committed page is stale
"""
import html
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SITE_DIR = REPO / "site"
CHANGELOG = REPO / "CHANGELOG.md"
DOCS = REPO / "docs"

# Ensure venv packages and site module are available
for venv_path in [REPO / ".venv", SITE_DIR / ".venv"]:
    if venv_path.exists():
        site_pkgs = list(venv_path.glob("lib/python*/site-packages"))
        for sp in site_pkgs:
            if str(sp) not in sys.path:
                sys.path.insert(0, str(sp))

if str(SITE_DIR) not in sys.path:
    sys.path.insert(0, str(SITE_DIR))

import i18n
import build

HEADER_RE = re.compile(r"^##\s+(?P<version>\S+)(?:\s+—\s+(?P<date>\d{4}-\d{2}-\d{2}))?\s*$")


def inline(text: str) -> str:
    """Escape HTML, then apply the two markdown flavors the changelog uses."""
    text = html.escape(text, quote=False)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    return text


def parse(md: str):
    releases = []  # (version, date, [bullets])
    current = None
    for line in md.splitlines():
        m = HEADER_RE.match(line)
        if m:
            current = (m.group("version"), m.group("date"), [])
            releases.append(current)
            continue
        if current is None or line.lstrip().startswith("<!--"):
            continue
        if line.startswith(("- ", "* ")):
            current[2].append(line[2:].strip())
        elif line.startswith("  ") and current[2]:  # continuation of a wrapped bullet
            current[2][-1] += " " + line.strip()
    # Drop empty sections, and the in-progress "Unreleased" staging section —
    # notes land on the site when they ship, under their real version.
    return [r for r in releases
            if r[2] and r[0].lower() != "unreleased"]


def pretty_date(iso: str | None, ctx=None) -> str:
    if not iso:
        return ""
    gettext = ctx.gettext if ctx else (lambda s: s)
    y, m, d = (int(x) for x in iso.split("-"))
    month_name = gettext(i18n.ENGLISH_MONTHS[m - 1])
    fmt = gettext("changelog_date_format")
    if not fmt or fmt == "changelog_date_format":
        fmt = gettext("date_format_long")
    if not fmt or fmt in ("date_format_long", "changelog_date_format"):
        fmt = "{month} {day}, {year}"
    return fmt.format(day=d, month=month_name, year=y)


def is_changelog_available(locale: str) -> bool:
    if locale == "en":
        return True
    cat = i18n.load_catalog(locale)
    return bool(cat and cat.get("Changelog — MeetMouse for Mac"))


def render(releases, locale="en", ctx=None) -> str:
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    loc = i18n.get_locale(locale)
    root = f"/{loc['root'].strip('/')}" if loc.get("root") else ""
    lang_tag = loc.get("lang_tag", "en")
    pfx = "../" if root else ""
    url = f"https://meetmouse.com{root}/changelog"

    title = _("Changelog — MeetMouse for Mac")
    desc = _("What's new in MeetMouse — every release, in plain language.")
    h1 = _("Changelog")
    sub = _("What's new in MeetMouse — every release, in plain language. The app updates itself automatically.")
    gh_link = _("Releases on GitHub")

    available_locales = [l for l in i18n.LOCALES if is_changelog_available(l)]
    alts = [("en", "/changelog")]
    hreflangs = [
        '  <link rel="alternate" hreflang="x-default" href="https://meetmouse.com/changelog">',
        '  <link rel="alternate" hreflang="en" href="https://meetmouse.com/changelog">',
    ]
    for l_key in available_locales:
        if l_key == "en":
            continue
        l_info = i18n.LOCALES[l_key]
        r = f"/{l_info['root'].strip('/')}" if l_info.get("root") else ""
        alts.append((l_info["lang_tag"], f"{r}/changelog"))
        hreflangs.append(f'  <link rel="alternate" hreflang="{l_info["code"]}" href="https://meetmouse.com{r}/changelog">')
    hreflang_html = "\n".join(hreflangs)
    if len(available_locales) > 1:
        hreflang_html += "\n" + build.LANG_SELECT_CSS

    rel_data = []
    for version, date, bullets in releases:
        rel_data.append({
            "version": version,
            "date_formatted": pretty_date(date, ctx=ctx),
            "bullets": [inline(ctx.gettext(b)) for b in bullets]
        })

    lang_dropdown = build.lang_dropdown("changelog", locale=locale, alternates=alts)

    env = i18n.create_jinja_env(locale)
    tmpl = env.get_template("changelog.html")
    return tmpl.render(
        lang_tag=lang_tag,
        title=title,
        desc=desc,
        url=url,
        hreflang_html=hreflang_html,
        rel_prefix=pfx,
        pfx=pfx,
        home_url=build.resolve_url("/", locale),
        h1=h1,
        sub=sub,
        releases=rel_data,
        gh_link=gh_link,
        lang_dropdown=lang_dropdown,
    )


def main():
    releases = parse(CHANGELOG.read_text(encoding="utf-8"))
    if not releases:
        sys.exit("no releases parsed from CHANGELOG.md")

    available_locales = [l for l in i18n.LOCALES if is_changelog_available(l)]
    target_files = {}
    for loc_key in available_locales:
        loc_info = i18n.LOCALES[loc_key]
        ctx = i18n.TranslationContext(loc_key)
        content = render(releases, locale=loc_key, ctx=ctx)
        if loc_key == "en":
            target_files[DOCS / "changelog.html"] = content
        else:
            r = loc_info["root"].strip("/")
            target_files[DOCS / r / "changelog.html"] = content

    if "--check" in sys.argv:
        for out_path, expected in target_files.items():
            if not out_path.exists() or out_path.read_text(encoding="utf-8") != expected:
                sys.exit(f"{out_path.relative_to(REPO)} is stale — run: python3 scripts/build-changelog.py")
        print(f"changelog: all {len(target_files)} changelog pages are current ({len(releases)} releases)")
        return

    for out_path, content in target_files.items():
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(content, encoding="utf-8")
        print(f"wrote {out_path.relative_to(REPO)} ({len(releases)} releases, latest {releases[0][0]})")

    # The sitemap covers every docs/ page (changelog included) — regenerate
    # it here so the pre-release ritual can't leave it stale.
    subprocess.run(
        [sys.executable, str(REPO / "scripts" / "build-sitemap.py")], check=False
    )


if __name__ == "__main__":
    main()
