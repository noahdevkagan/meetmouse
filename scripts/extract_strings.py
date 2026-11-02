#!/usr/bin/env python3
"""Extract translatable strings from MeetMouse templates, articles, content and Python sources.

Generates:
  site/locale/messages.pot
  site/locale/<lang>/LC_MESSAGES/messages.po
And compiles to messages.mo for all configured locales.
"""
import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE_DIR = ROOT / "site"
ARTICLES_DIR = SITE_DIR / "articles"
TEMPLATES_DIR = SITE_DIR / "templates"
CONTENT_DIR = SITE_DIR / "content"
LOCALE_DIR = SITE_DIR / "locale"

# Ensure venv packages are available
for venv_path in [ROOT / ".venv", SITE_DIR / ".venv"]:
    if venv_path.exists():
        site_pkgs = list(venv_path.glob("lib/python*/site-packages"))
        for sp in site_pkgs:
            if str(sp) not in sys.path:
                sys.path.insert(0, str(sp))

if str(SITE_DIR) not in sys.path:
    sys.path.insert(0, str(SITE_DIR))
if str(CONTENT_DIR) not in sys.path:
    sys.path.insert(0, str(CONTENT_DIR))

from babel.messages import Catalog, pofile
from babel.messages.extract import extract_python
from babel.messages.mofile import write_mo
from jinja2.ext import babel_extract
import i18n


def get_latest_version() -> str:
    changelog = ROOT / "CHANGELOG.md"
    if changelog.exists():
        for line in changelog.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^##\s+(\S+)", line)
            if m and m.group(1).lower() != "unreleased":
                return m.group(1)
    return "0.1.0"


def extract_all():
    version = get_latest_version()
    catalog_pot = Catalog(project="MeetMouse", version=version, copyright_holder="MeetMouse", fuzzy=False)

    def add_msg(msgid, location=None):
        if not msgid:
            return
        clean_id = msgid.strip() if isinstance(msgid, str) else msgid
        if not clean_id:
            return

        locs = [location] if location else []
        is_printf = bool(re.search(r"%\([a-zA-Z0-9_]+\)s|%[sdfrxXo]", clean_id))

        if clean_id not in catalog_pot:
            msg_pot = catalog_pot.add(clean_id, locations=locs)
            if "%" in clean_id and not is_printf:
                msg_pot.flags.discard("python-format")
                msg_pot.flags.add("no-python-format")
        else:
            msg = catalog_pot[clean_id]
            if location and location not in msg.locations:
                msg.locations.append(location)
            if "%" in clean_id and not is_printf:
                msg.flags.discard("python-format")
                msg.flags.add("no-python-format")

    # 1. Templates & Articles (using Jinja2 babel extractor)
    for folder in [TEMPLATES_DIR, ARTICLES_DIR]:
        for html_file in sorted(folder.glob("*.html")):
            rel_path = f"site/{folder.name}/{html_file.name}"
            with open(html_file, "rb") as f:
                for lineno, func, msg, comments in babel_extract(f, ["_", "gettext"], [], {}):
                    if isinstance(msg, str):
                        add_msg(msg, (rel_path, lineno))
                    elif isinstance(msg, (list, tuple)):
                        for m in msg:
                            if m:
                                add_msg(m, (rel_path, lineno))

    # 2. Python source files (site/build.py, scripts/build-changelog.py)
    # Use AST to extract only literal arguments to _() and gettext()
    # (avoiding Babel's extract_python quirk of extracting dict keys from subscripts like _(p["key"]))
    for py_file in [SITE_DIR / "build.py", ROOT / "scripts" / "build-changelog.py"]:
        rel_path = str(py_file.relative_to(ROOT))
        tree = ast.parse(py_file.read_text(encoding="utf-8"), filename=str(py_file))
        for node in ast.walk(tree):
            if isinstance(node, ast.Call):
                func_name = None
                if isinstance(node.func, ast.Name):
                    func_name = node.func.id
                elif isinstance(node.func, ast.Attribute):
                    func_name = node.func.attr
                if func_name in ("_", "gettext") and node.args:
                    first = node.args[0]
                    if isinstance(first, ast.Constant) and isinstance(first.value, str):
                        add_msg(first.value, (rel_path, node.lineno))

    # 3. Structured content files
    # best.py
    from best import BEST
    rel_best = "site/content/best.py"
    for p in BEST:
        add_msg(p["title"], (rel_best, 1))
        add_msg(p["description"], (rel_best, 1))
        add_msg(p["headline"], (rel_best, 1))
        add_msg(p["dek"], (rel_best, 1))
        add_msg(p["label"], (rel_best, 1))
        add_msg(p["blurb"], (rel_best, 1))
        add_msg(p["short_answer"], (rel_best, 1))
        if p.get("cta_body"):
            add_msg(p["cta_body"], (rel_best, 1))
        for k, v in p.get("short_picks", []):
            add_msg(k, (rel_best, 1))
            add_msg(v, (rel_best, 1))
        for pk in p["picks"]:
            add_msg(pk["best_for"], (rel_best, 1))
            add_msg(pk["price"], (rel_best, 1))
            add_msg(pk["where"], (rel_best, 1))
            add_msg(pk["local"], (rel_best, 1))
            for b in pk.get("body", []):
                add_msg(b, (rel_best, 1))
        for h, ps in p.get("intro", []):
            add_msg(h, (rel_best, 1))
            for para in ps:
                add_msg(para, (rel_best, 1))
        for q, a in p.get("faq", []):
            add_msg(q, (rel_best, 1))
            add_msg(a, (rel_best, 1))
        for s in p.get("today", []):
            add_msg(s, (rel_best, 1))

    # compare.py
    from compare import COMPARE
    rel_comp = "site/content/compare.py"
    for p in COMPARE:
        add_msg(p["title"], (rel_comp, 1))
        add_msg(p["description"], (rel_comp, 1))
        add_msg(p["headline"], (rel_comp, 1))
        add_msg(p["dek"], (rel_comp, 1))
        add_msg(p.get("blurb", ""), (rel_comp, 1))
        add_msg(p.get("short_answer", ""), (rel_comp, 1))
        add_msg(p.get("pick_them", ""), (rel_comp, 1))
        add_msg(p.get("pick_mm", ""), (rel_comp, 1))
        for r in p.get("rows", []):
            for cell in r:
                add_msg(cell, (rel_comp, 1))
        for h, ps in p.get("sections", []):
            add_msg(h, (rel_comp, 1))
            for para in ps:
                add_msg(para, (rel_comp, 1))
        for q, a in p.get("faq", []):
            add_msg(q, (rel_comp, 1))
            add_msg(a, (rel_comp, 1))

    # alternatives.py
    from alternatives import PAGES as ALT_PAGES, TOOLS, NOT_RANKED, CHECKED as ALT_CHECKED
    rel_alt = "site/content/alternatives.py"
    for p in ALT_PAGES:
        add_msg(p["title"], (rel_alt, 1))
        add_msg(p["description"], (rel_alt, 1))
        if p.get("topic"):
            add_msg(p["topic"], (rel_alt, 1))
        add_msg(p.get("h1", ""), (rel_alt, 1))
        add_msg(p.get("intro", ""), (rel_alt, 1))
        add_msg(p.get("quick", ""), (rel_alt, 1))
        if p.get("us_best"):
            add_msg(p["us_best"], (rel_alt, 1))
        add_msg(p.get("enough", ""), (rel_alt, 1))
        if p.get("checked"):
            add_msg(p["checked"], (rel_alt, 1))
        for q, a in p.get("faqs", []):
            add_msg(q, (rel_alt, 1))
            add_msg(a, (rel_alt, 1))

    for k, t in TOOLS.items():
        add_msg(t["best"], (rel_alt, 1))
        add_msg(t["price"], (rel_alt, 1))
        add_msg(t["cell"], (rel_alt, 1))
        add_msg(t["free"], (rel_alt, 1))
        add_msg(t["bot"], (rel_alt, 1))
        add_msg(t["audio"], (rel_alt, 1))
        add_msg(t["review"], (rel_alt, 1))
        for g in t.get("good", []):
            add_msg(g, (rel_alt, 1))
        for b in t.get("bad", []):
            add_msg(b, (rel_alt, 1))

    for k, nr in NOT_RANKED.items():
        add_msg(nr[0], (rel_alt, 1))
        add_msg(nr[1], (rel_alt, 1))

    # links.py
    from links import BLOG, MM_VS_ARTICLES, X_VS_Y, RHINO, RHINO_GUIDES
    rel_links = "site/content/links.py"
    for href, label, blurb in BLOG:
        add_msg(label, (rel_links, 1))
        add_msg(blurb, (rel_links, 1))
    for href, label, blurb in MM_VS_ARTICLES:
        add_msg(label, (rel_links, 1))
        add_msg(blurb, (rel_links, 1))
    for href, label, blurb in X_VS_Y:
        add_msg(label, (rel_links, 1))
        add_msg(blurb, (rel_links, 1))
    if RHINO:
        add_msg(RHINO[1], (rel_links, 1))
        add_msg(RHINO[2], (rel_links, 1))
    if RHINO_GUIDES:
        add_msg(RHINO_GUIDES[1], (rel_links, 1))

    # build.py constants
    import build
    add_msg(build.FREE_CTA, ("site/build.py", 1))

    # 4. Months from site/i18n.py
    for month in i18n.ENGLISH_MONTHS:
        add_msg(month, ("site/i18n.py", 62))

    # 5. CHANGELOG.md bullet points
    changelog_path = ROOT / "CHANGELOG.md"
    if changelog_path.exists():
        import importlib.util
        spec = importlib.util.spec_from_file_location("build_changelog", ROOT / "scripts" / "build-changelog.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        releases = mod.parse(changelog_path.read_text(encoding="utf-8"))
        for rel_version, rel_date, bullets in releases:
            for b in bullets:
                add_msg(b, ("CHANGELOG.md", 1))

    # Clean POT flags
    for msg in catalog_pot:
        is_printf = bool(re.search(r"%\([a-zA-Z0-9_]+\)s|%[sdfrxXo]", msg.id))
        if "%" in msg.id and not is_printf:
            msg.flags.discard("python-format")
            msg.flags.add("no-python-format")
        elif "no-python-format" in msg.flags:
            msg.flags.discard("python-format")

    # Write POT
    pot_path = LOCALE_DIR / "messages.pot"
    LOCALE_DIR.mkdir(parents=True, exist_ok=True)
    with open(pot_path, "wb") as f:
        pofile.write_po(f, catalog_pot)
    print(f"Wrote {len(catalog_pot)} messages to {pot_path.relative_to(ROOT)}")

    # Update PO and compile MO for each non-English locale
    for loc_key, loc_info in i18n.LOCALES.items():
        if loc_key == "en":
            continue
        po_name = loc_info.get("po_name", loc_key.replace("-", "_"))
        po_path = LOCALE_DIR / po_name / "LC_MESSAGES" / "messages.po"

        existing_po = {}
        old_cat = None
        if po_path.exists():
            with open(po_path, "rb") as f:
                old_cat = pofile.read_po(f)
                for m in old_cat:
                    if m.id and m.string:
                        s = m.string if isinstance(m.string, str) else m.string[0]
                        if s:
                            existing_po[m.id] = s

        catalog_po = Catalog(project="MeetMouse", version=version, locale=po_name, copyright_holder="MeetMouse", fuzzy=False)
        if old_cat:
            if old_cat.header_comment:
                catalog_po.header_comment = old_cat.header_comment.replace("ORGANIZATION", "MeetMouse")
            if old_cat.last_translator and "FULL NAME" not in old_cat.last_translator:
                catalog_po.last_translator = old_cat.last_translator
            if old_cat.revision_date and "YEAR-MO-DA" not in str(old_cat.revision_date):
                catalog_po.revision_date = old_cat.revision_date
        for msg in catalog_pot:
            if not msg.id:
                continue
            str_val = existing_po.get(msg.id, "")
            msg_po = catalog_po.add(
                msg.id,
                string=str_val,
                locations=list(msg.locations),
            )
            is_printf = bool(re.search(r"%\([a-zA-Z0-9_]+\)s|%[sdfrxXo]", msg.id))
            if "%" in msg.id and not is_printf:
                msg_po.flags.discard("python-format")
                msg_po.flags.add("no-python-format")
            elif "no-python-format" in msg.flags:
                msg_po.flags.discard("python-format")

        po_path.parent.mkdir(parents=True, exist_ok=True)
        with open(po_path, "wb") as f:
            pofile.write_po(f, catalog_po)
        translated_cnt = sum(1 for m in catalog_po if m.string)
        print(f"[{loc_key}] Wrote {len(catalog_po)} messages ({translated_cnt} translated) to {po_path.relative_to(ROOT)}")

        mo_path = po_path.with_suffix(".mo")
        with open(mo_path, "wb") as f:
            write_mo(f, catalog_po)
        print(f"[{loc_key}] Compiled MO catalog to {mo_path.relative_to(ROOT)}.")


if __name__ == "__main__":
    extract_all()
