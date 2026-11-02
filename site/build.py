#!/usr/bin/env python3
"""Build every MeetMouse content page from one template.

    python3 site/build.py          # write docs/**
    python3 site/build.py --check  # fail if docs/ is stale or links are broken

Sources:
  site/content/best.py              /best/* guides (structured)
  site/content/compare.py           structured "MeetMouse vs X" pages
  site/content/alternatives.py      ranked "<tool> alternatives" blog posts
  site/content/links.py             the one list of pages; hubs, "more" blocks, llms.txt read it
  site/content/home.py              homepage data
  site/articles/*.html              long-form articles
  site/locale/**                    GNU Gettext PO catalogs (UI chrome & structured data)

The changelog (scripts/build-changelog.py), 404, thanks and appsumo pages
are utility pages. Shared CSS lives in docs/site.css.
See SITE-PLAYBOOK.md for the writing and cross-linking rules.
"""
import html
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parent
DOCS = REPO / "docs"
BASE = "https://meetmouse.com"

# Ensure virtualenv packages (jinja2, babel) are accessible
for venv_path in [REPO / ".venv", ROOT / ".venv"]:
    if venv_path.exists():
        site_pkgs = list(venv_path.glob("lib/python*/site-packages"))
        for sp in site_pkgs:
            if str(sp) not in sys.path:
                sys.path.insert(0, str(sp))

sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "content"))

import i18n
from pricing import PRICES, get_page_pricing_context

from alternatives import CHECKED as ALT_CHECKED, MODIFIED as ALT_MODIFIED, NOT_RANKED, PAGES as ALT_PAGES, TOOLS  # noqa: E402
from best import BEST  # noqa: E402
from compare import COMPARE  # noqa: E402
from links import BLOG, MM_VS_ARTICLES, RHINO, RHINO_GUIDES, X_VS_Y  # noqa: E402

esc = html.escape
OG_ALT = "MeetMouse: free meeting notes, nothing leaves your Mac. Live coaching too."

BEST_LINKS = [("/" + p["slug"], p["label"], p["blurb"]) for p in BEST]
MM_VS = MM_VS_ARTICLES + [("/" + p["slug"], "MeetMouse vs " + p["competitor"], p["blurb"]) for p in COMPARE]
COMPARISONS = MM_VS + X_VS_Y

ARTICLE_FILES = sorted((ROOT / "articles").glob("*.html"))
ARTICLE_SLUGS = [(af.stem.replace("__", "/"), af) for af in ARTICLE_FILES]

REDIRECTS_MARKER = "# Dynamic language fallbacks (managed by site/build.py)"


# ── alternate mapping (reciprocal hreflang clusters) ──────────────────────────

def get_canonical_path(norm_path):
    clean = norm_path.strip("/")
    for loc in i18n.LOCALES.values():
        root = loc["root"].strip("/")
        if root:
            if clean == root:
                return ""
            if clean.startswith(root + "/"):
                return clean[len(root) + 1:]
    return clean


def rel_prefix(path: str) -> str:
    clean = path.strip("/")
    if not clean:
        return ""
    is_dir = clean in ("best", "alternatives", "blog") or clean in [loc.get("root", "").strip("/") for loc in i18n.LOCALES.values() if loc.get("root")]
    is_dir = is_dir or any(clean == f"{loc['root'].strip('/')}/{sub}" for loc in i18n.LOCALES.values() if loc.get("root") for sub in ("best", "alternatives", "blog"))
    depth = clean.count("/") + (1 if is_dir else 0)
    return "../" * depth


def get_template_first_string(tmpl_path: Path) -> str:
    if not tmpl_path.exists():
        return ""
    raw = tmpl_path.read_text(encoding="utf-8")
    m = re.search(r'_\(["\'](.*?)["\']\)', raw)
    return m.group(1) if m else ""


def is_page_available(canon, locale):
    if locale == "en":
        return True
    cat = i18n.load_catalog(locale)
    if not cat:
        return False
    if canon in ("best", "alternatives", "blog"):
        hub_title = "Best AI Meeting Tools by Use Case (2026) — MeetMouse" if canon == "best" \
            else "MeetMouse vs Granola, Fathom, Otter & More (2026) — Comparisons" if canon == "alternatives" \
            else "Blog — MeetMouse"
        return hub_title in cat and bool(cat[hub_title])
    if canon == "":
        return "MeetMouse — free, private meeting notes for Mac" in cat and bool(cat["MeetMouse — free, private meeting notes for Mac"])
    if canon.startswith("best/"):
        p = next((x for x in BEST if x["slug"] == canon), None)
        return p is not None and p["title"] in cat and bool(cat[p["title"]])
    if canon.startswith("compare/"):
        p = next((x for x in COMPARE if x["slug"] == canon), None)
        if p is not None:
            return p["title"] in cat and bool(cat[p["title"]])
    if canon.startswith("blog/"):
        slug = canon[len("blog/"):]
        p = next((x for x in ALT_PAGES if x["slug"] == slug), None)
        if p is not None:
            return p["title"] in cat and bool(cat[p["title"]])
        stem = canon.replace("/", "__") + ".html"
        art_file = ROOT / "articles" / stem
        if art_file.exists():
            raw = art_file.read_text(encoding="utf-8")
            m = re.search(r'"title":\s*_\(["\'](.*?)["\']\)', raw)
            if m:
                title = m.group(1)
                return title in cat and bool(cat[title])
    stem = canon.replace("/", "__") + ".html"
    art_file = ROOT / "articles" / stem
    if art_file.exists():
        raw = art_file.read_text(encoding="utf-8")
        m = re.search(r'"title":\s*_\(["\'](.*?)["\']\)', raw)
        if m:
            title = m.group(1)
            return title in cat and bool(cat[title])
    if canon == "changelog":
        return bool(cat and cat.get("Changelog — MeetMouse for Mac"))
    if canon in ("404", "thanks", "appsumo"):
        tmpl_file = ROOT / "templates" / f"{canon}.html"
        if not tmpl_file.exists():
            return False
        first_str = get_template_first_string(tmpl_file)
        return bool(first_str and cat.get(first_str))
    return False


def get_alternates(norm_path):
    """Return list of (lang, href) for reciprocal hreflang clusters."""
    canon = get_canonical_path(norm_path)
    is_dir = canon in ("", "best", "alternatives", "blog")
    suffix = "/" if is_dir else ""

    en_href = "/" + canon + suffix if canon else "/"
    alts = [("en", en_href)]

    for loc_key, loc in i18n.LOCALES.items():
        if loc_key == "en":
            continue
        if is_page_available(canon, loc_key):
            root = loc["root"].strip("/")
            alts.append((loc["lang_tag"], f"/{root}/{canon}{suffix}" if canon else f"/{root}/"))
    return alts


def resolve_url(target_path: str, locale: str = "en") -> str:
    """Resolve an internal path to its locale-aware URL based on translation availability."""
    if not target_path:
        return target_path
    clean = target_path.strip("/")
    loc = i18n.get_locale(locale)
    root = loc.get("root", "").strip("/")
    if not clean:
        return f"/{root}/" if (root and is_page_available("", locale)) else "/"
    trailing = "/" if target_path.endswith("/") else ""
    if root and is_page_available(clean, locale):
        return f"/{root}/{clean}{trailing}"
    return f"/{clean}{trailing}"


# ── chrome ───────────────────────────────────────────────────────────────────

FREE_CTA = ("Free to start: unlimited your first week, then 3 meetings a week, and your notes are never locked. "
            "Invite 2 friends or pay {price} once for unlimited. No subscription, no account.")


def get_free_cta(locale="en", ctx=None, cta_body=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    raw = ctx.gettext(cta_body or FREE_CTA)
    try:
        return raw.format(**get_page_pricing_context())
    except (KeyError, ValueError):
        return raw


def download_button(compact=False, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    text = _("Download free") if compact else _("Download MeetMouse free")
    cls = "button button-compact" if compact else "button"
    return f'<a class="{cls}" href="/get">{text}</a>'


def buy_form(compact=False, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    loc = i18n.get_locale(locale)
    cancel_url = f"{BASE}{loc['root']}/" if loc["root"] else f"{BASE}/"
    item_name = _("MeetMouse Unlimited for Mac")
    price = PRICES.meetmouse.price
    label = _("Buy MeetMouse Unlimited — {price}").format(price=price) if compact else _("Or buy MeetMouse Unlimited — {price} once").format(price=price)
    cls = "buy-form buy-form-compact" if compact else "buy-form buy-form-inline"
    btn = "button button-compact" if compact else "link-button"
    return f"""<form class="{cls}" action="https://www.paypal.com/cgi-bin/webscr" method="post">
        <input type="hidden" name="cmd" value="_xclick">
        <input type="hidden" name="business" value="paypal@okdork.com">
        <input type="hidden" name="item_name" value="{item_name}">
        <input type="hidden" name="amount" value="20.00">
        <input type="hidden" name="currency_code" value="USD">
        <input type="hidden" name="no_shipping" value="1">
        <input type="hidden" name="return" value="https://meetmouse.com/thanks.html">
        <input type="hidden" name="cancel_return" value="{cancel_url}">
        <button class="{btn}" type="submit">{label}</button>
      </form>"""


def lang_dropdown(norm_path="", locale="en", alternates=None):
    alts = alternates if alternates is not None else get_alternates(norm_path)
    real_alts = [(l, h) for l, h in alts if l != "x-default"]
    if len(real_alts) <= 1:
        return ""
    current_loc = i18n.get_locale(locale)
    current_tag = current_loc.get("lang_tag", locale).lower()
    opts = []
    for l_tag, href in real_alts:
        loc_info = i18n.get_locale(l_tag)
        display_name = loc_info.get("name", l_tag)
        is_sel = " selected" if (l_tag.lower() == current_tag or loc_info.get("code", "").lower() == current_tag) else ""
        opts.append(f'<option value="{href}" data-lang="{loc_info.get("code", l_tag)}"{is_sel}>{esc(display_name)}</option>')
    return f'<select class="lang-select" aria-label="Language">\n' + "\n".join(f"        {opt}" for opt in opts) + "\n      </select>\n"


def header_markup(locale="en", norm_path="", alternates=None, ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    home_href = resolve_url("/", locale)
    pfx = rel_prefix(norm_path)

    nav_links = f"""      <a href="{resolve_url('/best/', locale)}">{_("Guides")}</a>
      <a href="{resolve_url('/alternatives/', locale)}">{_("Comparisons")}</a>
      <a href="{resolve_url('/blog/', locale)}">{_("Blog")}</a>
"""
    lang_sel = lang_dropdown(norm_path, locale, alternates=alternates)
    dropdown_html = f"      {lang_sel}\n" if lang_sel else ""

    return f"""  <a class="skip-link" href="#main">{_("Skip to content")}</a>
  <header class="site-header">
    <a class="brand" href="{home_href}" aria-label="{_("MeetMouse home")}">
      <span class="mark"><img src="{pfx}icon.png" alt=""></span>
      <span>MeetMouse</span>
    </a>
    <nav aria-label="{_("Main navigation")}">
{nav_links}{dropdown_html}      {download_button(compact=True, locale=locale, ctx=ctx)}
    </nav>
  </header>"""


def footer_markup(locale="en", ctx=None, canon=""):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    rhino_text = _("Also by me: Rhino Voice, private Mac dictation")
    hub_links = f"""    <a href="{resolve_url('/best/', locale)}">{_("Meeting tool guides")}</a>
    <a href="{resolve_url('/alternatives/', locale)}">{_("Comparisons")}</a>
    <a href="{resolve_url('/blog/', locale)}">{_("Blog")}</a>"""

    return f"""  <footer>
    <span>MeetMouse</span>
    <a href="mailto:support@meetmouse.com">support@meetmouse.com</a>
{hub_links}
    <a href="{resolve_url('/changelog', locale)}">{_("Changelog")}</a>
    <a href="https://github.com/noahdevkagan/meeting-coach-releases/releases">{_("Releases on GitHub")}</a>
    <a href="{RHINO[0]}">{rhino_text}</a>
  </footer>"""


LANG_SELECT_CSS = """<style>
.lang-select {
  appearance: none;
  -webkit-appearance: none;
  -moz-appearance: none;
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  font-size: 13px;
  font-weight: 550;
  color: #1a1a1a;
  background-color: #ffffff;
  border: 1px solid #e5ded8;
  border-radius: 8px;
  padding: 5px 28px 5px 11px;
  cursor: pointer;
  outline: none;
  background-image: url("data:image/svg+xml,%3Csvg width='10' height='6' viewBox='0 0 10 6' fill='none' xmlns='http://www.w3.org/2000/svg'%3E%3Cpath d='M1 1L5 5L9 1' stroke='%23444444' stroke-width='1.5' stroke-linecap='round' stroke-linejoin='round'/%3E%3C/svg%3E");
  background-repeat: no-repeat;
  background-position: right 10px center;
  background-size: 10px 6px;
  line-height: 1.4;
  vertical-align: middle;
  transition: border-color 0.15s ease, box-shadow 0.15s ease;
}
.lang-select:hover {
  border-color: #bbbbbb;
}
.lang-select:focus {
  border-color: #2bbd3e;
  box-shadow: 0 0 0 2px rgba(43, 189, 62, 0.15);
}
</style>"""


def hreflang_links(alternates):
    if not alternates:
        return ""
    links = [f'<link rel="alternate" hreflang="{l}" href="{BASE}{h}">' for l, h in alternates]
    en = next((h for l, h in alternates if l == "en"), None)
    if en:
        links.append(f'<link rel="alternate" hreflang="x-default" href="{BASE}{en}">')
    links_html = "\n".join(links) + "\n"
    if len(alternates) > 1:
        return links_html + LANG_SELECT_CSS + "\n"
    return links_html


def head(title, desc, path, og_type, ld, lang="en", alternates=(), locale="en", ctx=None):
    clean = path.strip("/")
    loc_root = clean.split("/")[0] if "/" in clean else clean
    is_dir = clean in ("", "best", "alternatives", "blog") or clean in [loc.get("root", "").strip("/") for loc in i18n.LOCALES.values() if loc.get("root")]
    is_dir = is_dir or any(clean == f"{loc['root'].strip('/')}/{sub}" for loc in i18n.LOCALES.values() if loc.get("root") for sub in ("best", "alternatives", "blog"))
    url = f"{BASE}/{clean}/" if is_dir else (f"{BASE}/{clean}" if clean else f"{BASE}/")

    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    pfx = rel_prefix(path)
    lds = "\n".join('<script type="application/ld+json">' + json.dumps(b, ensure_ascii=False) + "</script>" for b in ld)
    og_alt = _(OG_ALT)
    return f"""<!doctype html>
<html lang="{lang}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{url}">
{hreflang_links(alternates)}<script src="{pfx}lang.js" defer></script>
<link rel="icon" type="image/png" href="{pfx}icon.png">
<meta property="og:type" content="{og_type}">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{BASE}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{og_alt}">
<meta name="twitter:card" content="summary_large_image">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400..800&family=Geist+Mono:wght@500..700&display=swap">
<link rel="stylesheet" href="{pfx}site.css">
{lds}
</head>"""


def page(title, desc, path, og_type, ld, main, lang="en", alternates=(), header=None, locale="en", ctx=None):
    norm_path = path.strip("/")
    hdr = header if header is not None else header_markup(locale, norm_path=norm_path, alternates=alternates, ctx=ctx)
    ftr = footer_markup(locale, ctx=ctx, canon=get_canonical_path(path))
    return (head(title, desc, path, og_type, ld, lang, alternates, locale=locale, ctx=ctx) + '\n<body>\n<div class="doc-page">\n' + hdr
            + '\n  <main class="doc" id="main">\n' + main + "\n  </main>\n" + ftr + "\n</div>\n</body>\n</html>\n")


# ── shared blocks ────────────────────────────────────────────────────────────

def crumbs_data(parent, label, locale="en", ctx=None):
    root = i18n.locale_root(locale)
    home_href = f"/{root}" if (root and is_page_available("", locale)) else "/"
    items = [(home_href, "MeetMouse")]
    if parent:
        items.append(parent)
    items.append(("", label))
    return items


def crumbs(parent, label, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    data = crumbs_data(parent, label, locale=locale, ctx=ctx)
    out = "".join(f'<a href="{h}">{esc(t)}</a><span aria-hidden="true">/</span>' for h, t in data[:-1])
    return f'    <nav class="breadcrumb" aria-label="{_("Breadcrumb")}">{out}<span>{esc(data[-1][1])}</span></nav>'


def crumb_ld(parent, label, path, locale="en"):
    root = i18n.locale_root(locale)
    home_href = f"{BASE}/{root}" if (root and is_page_available("", locale)) else f"{BASE}/"
    items = [("MeetMouse", home_href)] + ([(parent[1], BASE + parent[0])] if parent else []) + [(label, f"{BASE}/{path}")]
    return {"@context": "https://schema.org", "@type": "BreadcrumbList",
            "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": n, "item": u} for i, (n, u) in enumerate(items)]}


def faq_ld(faq):
    return {"@context": "https://schema.org", "@type": "FAQPage", "mainEntity": [
        {"@type": "Question", "name": q, "acceptedAnswer": {"@type": "Answer", "text": html.unescape(re.sub(r"<[^>]+>", "", a))}}
        for q, a in faq]}


def article_ld(title, date):
    return {"@context": "https://schema.org", "@type": "Article", "headline": title,
            "author": {"@type": "Person", "name": "Noah Kagan", "url": f"{BASE}/"},
            "datePublished": date, "publisher": {"@type": "Organization", "name": "MeetMouse"}}


def byline(when, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    role = _("Founder, MeetMouse")
    return ('    <div class="byline">\n      <img src="/img/noah.jpg" alt="Noah Kagan" width="44" height="44">\n'
            f'      <div><strong>Noah Kagan</strong><span>{role} · {when}</span></div>\n    </div>')


def long_date(iso, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    return i18n.format_long_date(iso, ctx=ctx)


def faq_block(faq, locale="en", ctx=None):
    if not faq:
        return ""
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    heading = _("Questions")
    items = "".join(f"\n        <div><dt>{q}</dt><dd>{a}</dd></div>" for q, a in faq)
    return f'    <section>\n      <h2>{heading}</h2>\n      <dl class="faq">{items}\n      </dl>\n    </section>'


def top_cta(locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    btn = f'<a class="button" href="/get">{_("Download MeetMouse free")}</a>'
    span = _("Free for 3 meetings a week. No bot, and your meeting stays on your Mac.")
    return f'    <p class="top-cta">{btn}<span>{span}</span></p>'


def cta(body, heading=None, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    if not heading:
        heading = _("Try MeetMouse")
    if "{price}" in body:
        body = body.format(price="$20")
    return f'    <section class="doc-cta">\n      <h2>{heading}</h2>\n      <p>{body}</p>\n      {download_button(locale=locale, ctx=ctx)}\n    </section>'


def checked_note_text(month, legal=False, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    extra = (" " + _("And I'm not your lawyer, doctor or compliance officer.")) if legal else ""
    return _("I checked prices and features for the tools here in {month}. This stuff changes constantly, so double-check before you buy.{extra}").format(month=month, extra=extra)


def checked_note(month, legal=False, locale="en", ctx=None):
    return f'    <p class="checked-note">{checked_note_text(month, legal=legal, locale=locale, ctx=ctx)}</p>'


def more_links_data(current, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext
    root = i18n.locale_root(locale)

    loc_best = [(f"/{root}" + p["slug"].lstrip("/"), _(p["label"])) for p in BEST if (f"/{root}" + p["slug"].lstrip("/")) != current]
    loc_mm_vs_articles = [(f"/{root}" + h.lstrip("/"), _(t)) for h, t, b in MM_VS_ARTICLES if (f"/{root}" + h.lstrip("/")) != current]
    loc_mm_vs_compare = [(f"/{root}" + p["slug"].lstrip("/"), "MeetMouse vs " + (p.get("competitor") or "")) for p in COMPARE if (f"/{root}" + p["slug"].lstrip("/")) != current]
    loc_mm_vs = loc_mm_vs_articles + loc_mm_vs_compare
    loc_blog = [(f"/{root}" + h.lstrip("/"), _(t)) for h, t, b in BLOG if (f"/{root}" + h.lstrip("/")) != current]
    return loc_best, loc_mm_vs, loc_blog


def more_links(current, locale="en", ctx=None, alternates=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    loc_best, loc_mm_vs, loc_blog = more_links_data(current, locale=locale, ctx=ctx)

    def ul(links):
        return "<ul>" + "".join(f'<li><a href="{h}">{esc(t)}</a></li>' for h, t in links) + "</ul>"

    return f"""    <nav class="more-links" aria-label="{_("More guides")}">
      <h2>{_("More guides")}</h2>
      {ul(loc_best)}
      <h2>{_("Comparisons")}</h2>
      {ul(loc_mm_vs)}
      <h2>{_("From the blog")}</h2>
      {ul(loc_blog)}
    </nav>"""


def table(header, rows, caption=None, mine_row=None, mm_first=False):
    cls = "compare-table" + (" mm-first" if mm_first else "")
    cap = f"<caption>{caption}</caption>" if caption else ""
    th = "".join(f'<th scope="col">{h or "&nbsp;"}</th>' for h in header)
    body = ""
    for r in rows:
        mine = ' class="is-mine"' if mine_row and mine_row(r) else ""
        labels = [re.sub(r"<[^>]+>", "", h).strip() for h in header[1:]]
        body += f'\n          <tr{mine}><th scope="row">{r[0]}</th>' + "".join(
            f'<td data-label="{esc(l)}">{c}</td>' for l, c in zip(labels, r[1:])) + "</tr>"
    return (f'    <div class="table-wrap">\n      <table class="{cls}">{cap}\n        <thead><tr>{th}</tr></thead>'
            f"\n        <tbody>{body}\n        </tbody>\n      </table>\n    </div>")


def paras(ps):
    return "\n".join(f"      <p>{p}</p>" for p in ps)


def section(heading, inner):
    return f"    <section>\n      <h2>{heading}</h2>\n{inner}\n    </section>"


def answer_box(label, text, items=()):
    li = "".join(f"<li>{i}</li>" for i in items)
    ul = f"\n      <ul>{li}</ul>" if items else ""
    return f'    <aside class="answer-box">\n      <h2>{label}</h2>\n      <p>{text}</p>{ul}\n    </aside>'


# ── page types ───────────────────────────────────────────────────────────────

def render_best(p, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    slug = p["slug"]
    root = i18n.locale_root(locale)
    path = root + slug
    norm_path = path.strip("/")
    alts = get_alternates(norm_path)
    hub = (f"/{root}best/", _("Guides"))

    headers = [_("App"), _("Best for"), _("Price"), _("Stays on your Mac")]
    caption = _("The picks at a glance")
    mine_suffix = f" ({_('mine')})"
    answer_title = _("TL;DR")
    my_pick = _("My pick")
    what_id_do = _("What I'd do today")
    meta_keys = ((_("Best for"), "best_for"), (_("Price"), "price"), (_("Where your meeting is processed"), "where"))

    best_global_vals = get_page_pricing_context()

    def tr_pick(pk):
        name = pk["name"]
        vals = pk.get("price_vals", {"price": "$20"})

        def fmt_str(val):
            tr = _(val)
            if "{" in tr:
                try:
                    return tr.format(**vals)
                except (KeyError, ValueError):
                    return tr
            return tr

        return {
            "name": name,
            "mine": pk.get("mine", False),
            "best_for": _(pk["best_for"]),
            "price": fmt_str(pk["price"]),
            "where": _(pk["where"]),
            "local": _(pk["local"]),
            "body": [fmt_str(b) for b in pk.get("body", [])],
            "url": pk.get("url", ""),
        }

    picks_tr = [tr_pick(pk) for pk in p["picks"]]
    table_rows = [[pk["name"] + (mine_suffix if pk.get("mine") else ""), pk["best_for"], pk["price"], pk["local"]] for pk in picks_tr]

    out = [crumbs(hub, _(p["label"]), locale=locale, ctx=ctx)]

    def fmt_best_global(val):
        tr = _(val)
        if "{" in tr:
            try:
                return tr.format(**best_global_vals)
            except (KeyError, ValueError):
                return tr
        return tr

    short_picks_tr = [f"<strong>{fmt_best_global(k)}:</strong> {fmt_best_global(v)}" for k, v in p.get("short_picks", [])]
    out += [f"    <h1>{_(p['headline'])}</h1>", f'    <p class="dek">{_(p["dek"])}</p>',
            answer_box(answer_title, _(p["short_answer"]), short_picks_tr), top_cta(locale=locale, ctx=ctx),
            table(headers, table_rows, caption=caption, mine_row=lambda r: r[0].endswith(mine_suffix))]

    for h, ps in p["intro"]:
        out.append(section(_(h), paras([_(para) for para in ps])))

    for i, pk in enumerate(picks_tr, 1):
        badge = f'<span class="mine-badge">{_("mine")}</span>' if pk.get("mine") else ""
        meta = "".join(f"<div><dt>{k}</dt><dd>{pk[field]}</dd></div>" for k, field in meta_keys)
        link = ""
        if pk.get("url"):
            ext = pk["url"].startswith("http")
            see_text = _("See what MeetMouse does")
            visit_text = _("Visit {name}").format(name=pk['name'])
            is_home = pk["url"] in ("/", "/br/", "/pt-br/")
            tgt_url = f"/{root}" if (is_home and root) else pk["url"]
            text = see_text if is_home else visit_text
            link = f'\n      <p><a class="inline-link" href="{tgt_url}"' + (' rel="noopener"' if ext else "") + f">{text}</a></p>"
        out.append(f'    <section class="pick">\n      <h2>{i}. {pk["name"]}{badge}</h2>\n      <dl class="pick-meta">{meta}</dl>\n'
                   + paras(pk["body"]) + link + "\n    </section>")

    out.append(section(my_pick, paras([_(v) for v in p.get("verdict", [])])))
    today_lis = "".join(f"<li>{_(s)}</li>" for s in p.get("today", []))
    out.append(section(what_id_do, f'      <ol class="today">{today_lis}</ol>'))

    faq_tr = [(fmt_best_global(q), fmt_best_global(a)) for q, a in p.get("faq", [])]
    free_cta = get_free_cta(locale=locale, ctx=ctx, cta_body=p.get("cta_body"))
    out += [faq_block(faq_tr, locale=locale, ctx=ctx), cta(free_cta, locale=locale, ctx=ctx),
            checked_note(_(p.get("checked", "October 2026")), legal=True, locale=locale, ctx=ctx),
            more_links("/" + path, locale=locale, ctx=ctx, alternates=alts)]

    ld = [crumb_ld(hub, _(p["label"]), path, locale=locale),
          {"@context": "https://schema.org", "@type": "ItemList", "name": _(p["label"]),
           "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": pk["name"]} for i, pk in enumerate(picks_tr)]},
          faq_ld(faq_tr)]

    if locale != "en" and ctx.translated_count == 0:
        return None, None

    return path, page(_(p["title"]), _(p["description"]), path, "article", ld, "\n\n".join(out),
                      lang=i18n.get_locale(locale)["lang_tag"], alternates=alts, locale=locale, ctx=ctx)


def render_compare(p, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    slug = p["slug"]
    root = i18n.locale_root(locale)
    path = root + slug
    norm_path = path.strip("/")
    them = p["competitor"]
    label = f"MeetMouse vs {them}"
    alts = get_alternates(norm_path)
    hub = (f"/{root}alternatives/", _("Comparisons"))
    short_title = _("The short answer")
    pick_them_label = _("Pick {them} if").format(them=them)
    pick_mm_label = _("Pick MeetMouse if")
    caption = _("MeetMouse vs {them} at a glance").format(them=them)
    free_cta = get_free_cta(locale=locale, ctx=ctx)

    def fmt_compare(text):
        tr = _(text)
        if "{" in tr:
            try:
                return tr.format(**get_page_pricing_context())
            except (KeyError, ValueError):
                return tr
        return tr

    rows_tr = [[fmt_compare(c) for c in r] for r in p["rows"]]
    out = [crumbs(hub, label, locale=locale, ctx=ctx)]
    out += [f"    <h1>{_(p['headline'])}</h1>", f'    <p class="dek">{fmt_compare(p["dek"])}</p>',
            answer_box(short_title, fmt_compare(p["short_answer"]),
                       [f"<strong>{pick_them_label}</strong> {fmt_compare(p['pick_them'])}", f"<strong>{pick_mm_label}</strong> {fmt_compare(p['pick_mm'])}"]), top_cta(locale=locale, ctx=ctx),
            table(["", "MeetMouse", them], rows_tr, caption=caption, mm_first=True)]

    for h, ps in p["sections"]:
        out.append(section(_(h), paras([fmt_compare(para) for para in ps])))

    faq_tr = [(fmt_compare(q), fmt_compare(a)) for q, a in p.get("faq", [])]
    out += [faq_block(faq_tr, locale=locale, ctx=ctx),
            cta(free_cta, locale=locale, ctx=ctx),
            checked_note(_(p["checked"]), locale=locale, ctx=ctx), more_links("/" + path, locale=locale, ctx=ctx, alternates=alts)]
    ld = [crumb_ld(hub, label, path, locale=locale), faq_ld(faq_tr)]

    if locale != "en" and ctx.translated_count == 0:
        return None, None

    return path, page(_(p["title"]), _(p["description"]), path, "article", ld, "\n\n".join(out),
                      lang=i18n.get_locale(locale)["lang_tag"], alternates=alts, locale=locale, ctx=ctx)


def render_alternatives(p, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    root = i18n.locale_root(locale)
    slug = p["slug"]
    path = root + "blog/" + slug
    norm_path = path.strip("/")
    order = p["order"]
    alts = get_alternates(norm_path)
    has_blog = is_page_available("blog", locale)
    hub = (f"/{root}blog/", _("Blog")) if has_blog else None

    def tr_tool(k):
        t = TOOLS[k]
        vs_href = None
        if t.get("vs"):
            canon_vs = get_canonical_path(t["vs"])
            if is_page_available(canon_vs, locale):
                vs_href = f"/{root}" + canon_vs if root else f"/{canon_vs}"
        vals = t.get("price_vals", {"price": "$20"})

        def fmt_tool(text):
            tr = _(text)
            if "{" in tr:
                try:
                    return tr.format(**vals)
                except (KeyError, ValueError):
                    return tr
            return tr

        return {
            "name": t["name"],
            "best": fmt_tool(p["us_best"]) if (k == "meetmouse" and p.get("us_best")) else _(t["best"]),
            "price": fmt_tool(t["price"]),
            "cell": fmt_tool(t["cell"]),
            "free": _(t["free"]),
            "bot": _(t["bot"]),
            "audio": _(t["audio"]),
            "review": fmt_tool(t["review"]),
            "good": [fmt_tool(g) for g in t.get("good", [])],
            "bad": [fmt_tool(b) for b in t.get("bad", [])],
            "site": t.get("site"),
            "vs": vs_href,
        }

    tools_tr = {k: tr_tool(k) for k in TOOLS}

    def best_for(k):
        b = tools_tr[k]["best"]
        return b[0].lower() + b[1:]

    def name(k):
        suffix = f" ({_('mine')})"
        return esc(tools_tr[k]["name"]) + (suffix if k == "meetmouse" else "")

    byline_text = _("Founder, MeetMouse · Prices checked {date}").format(date=long_date("2026-10-20", locale=locale, ctx=ctx))
    quick_title = _("Quick answer")
    tbl_headers = [_("Tool"), _("Best for"), _("Price for one person")]
    tbl_caption = _("The ranking at a glance")
    mine_check = f"({_('mine')})"

    body_sections = [
        table(tbl_headers,
              [[f'{i}. <a href="#{k}">{name(k)}</a>', esc(best_for(k)), esc(tools_tr[k]["cell"])] for i, k in enumerate(order, 1)],
              caption=tbl_caption, mine_row=lambda r: mine_check in r[0])
    ]

    meta_labels = ((_("Best for"), "best_for"), (_("Price"), "price"), (_("Free plan"), "free"),
                   (_("Bot joins the call"), "bot"), (_("Where your audio goes"), "audio"))
    good_label = _("Good")
    bad_label = _("Not so good")

    for i, k in enumerate(order, 1):
        t, us = tools_tr[k], k == "meetmouse"
        badge = f'<span class="mine-badge">{_("mine")}</span>' if us else ""
        meta = "".join(f"<div><dt>{lbl}</dt><dd>{esc(best_for(k) if field == 'best_for' else t[field])}</dd></div>"
                       for lbl, field in meta_labels)
        shot = ""
        if us:
            fig_alt = _("MeetMouse during a call: live transcript, talk balance and coaching cues")
            fig_cap = _("MeetMouse during a call: live transcript, talk balance and coaching cues.")
            shot = (f'\n      <figure class="shot"><img src="/img/meetmouse-live-coaching.jpg" width="1200" height="522" loading="lazy" '
                    f'alt="{fig_alt}"><figcaption>{fig_cap}</figcaption></figure>')
            see_link = f"/{root}" if (root and is_page_available("", locale)) else "/"
            see_text = _("See what MeetMouse does")
            links = f'<a class="inline-link" href="{see_link}">{see_text}</a>'
        else:
            visit_text = _("Visit {name}").format(name=esc(t['name']))
            links = f'<a class="inline-link" href="{t["site"]}" rel="noopener">{visit_text}</a>'
            if t.get("vs"):
                vs_text = f"MeetMouse vs {esc(t['name'])}"
                links += f' · <a class="inline-link" href="{t["vs"]}">{vs_text}</a>'
        good = "".join(f"<li>{esc(x)}</li>" for x in t["good"])
        bad = "".join(f"<li>{esc(x)}</li>" for x in t["bad"])
        body_sections.append(f'    <section class="pick" id="{k}">\n      <h2>{i}. {esc(t["name"])}{badge}</h2>\n      <dl class="pick-meta">{meta}</dl>'
                   + shot + f"\n      <p>{esc(t['review'])}</p>\n      <h3>{good_label}</h3>\n      <ul>{good}</ul>\n"
                   f"      <h3>{bad_label}</h3>\n      <ul>{bad}</ul>\n      <p>{links}</p>\n    </section>")

    grid = order + ([] if p["incumbent"].lower() in order else [p["incumbent"].lower()])
    costs_heading = _("What each costs")
    grid_headers = [_("Tool"), _("Free plan"), _("Paid"), _("Bot joins?"), _("Where audio goes")]
    costs_p = _("Prices for one person, monthly billing, read from each tool's pricing page on {checked}. Check before you buy; these change.").format(checked=long_date(ALT_MODIFIED, locale=locale, ctx=ctx) if ALT_MODIFIED else _(ALT_CHECKED))
    body_sections.append(section(costs_heading, table(
        grid_headers,
        [[esc(tools_tr[k]["name"]), esc(tools_tr[k]["free"]), esc(tools_tr[k]["price"]), tools_tr[k]["bot"], esc(tools_tr[k]["audio"])] for k in grid],
        mine_row=lambda r: r[0] == "MeetMouse")
        + f"\n      <p>{costs_p}</p>"))

    alt_page_vals = get_page_pricing_context()

    def fmt_page_alt(text):
        tr = ctx.gettext(text)
        if "{" in tr:
            try:
                return tr.format(**alt_page_vals)
            except (KeyError, ValueError):
                return tr
        return tr

    when_enough = _("When {incumbent} is enough").format(incumbent=esc(p['incumbent']))
    body_sections.append(section(when_enough, paras([esc(fmt_page_alt(p["enough"]))])))

    nr = []
    for k in p["not_ranked"]:
        n_en, why_en, link_en = NOT_RANKED[k]
        n = _(n_en)
        why = _(why_en)
        canon_nr = get_canonical_path(link_en) if link_en else None
        link = f"/{root}" + canon_nr if (canon_nr and is_page_available(canon_nr, locale) and root) else (f"/{canon_nr}" if (canon_nr and is_page_available(canon_nr, locale)) else None)
        nr.append(f"<strong>{esc(n)}.</strong> {esc(why)}" + (f' <a href="{link}">MeetMouse vs {esc(n)}</a>' if link else ""))
    nr_heading = _("Checked, but not ranked")
    body_sections.append(section(nr_heading, paras(nr)))

    how_checked_heading = _("How I checked")
    how_checked_p = _(
        "Every price and plan limit is from the tool's own pricing page or docs on {checked}, for one person on monthly billing. "
        "The ranking is for individual Zoom/Meet/Teams users who care where their meetings go and want to get better at them — not a 50-person sales org. "
        "Nobody paid to be on this list. I make MeetMouse, and the price is what it costs on this site."
    ).format(checked=long_date(ALT_MODIFIED, locale=locale, ctx=ctx) if ALT_MODIFIED else _(ALT_CHECKED))
    body_sections.append(section(how_checked_heading, paras([how_checked_p])))

    how_to_switch_heading = _("How to switch")
    switch_paras = [
        _("Disconnect the bot from your Google Calendar or Outlook — that's how most of them join."),
        _("Download MeetMouse, open it, and grant the Screen Recording permission (that's how macOS lets tools capture system audio without a bot)."),
        _("Join your next meeting. MeetMouse starts transcribing and nudging you. When it's over, your summary and action items are right there."),
        _("If you need your old notetaker's archive, export your transcripts before you cancel."),
    ]
    body_sections.append(section(how_to_switch_heading, paras(switch_paras)))

    faq_tr = [(fmt_page_alt(q), fmt_page_alt(a)) for q, a in p.get("faqs", [])]
    free_cta = get_free_cta(locale=locale, ctx=ctx)
    crumbs_data_list = [(hub[0], hub[1])] if hub else []
    crumbs_data_list.append(("", ctx.gettext(p["topic"])))
    loc_best, loc_mm_vs, loc_blog = more_links_data("/" + path, locale=locale, ctx=ctx) if has_blog else ([], [], [])

    env = i18n.create_jinja_env(locale)
    article_tmpl = env.get_template("article.html")
    main = article_tmpl.render(
        breadcrumbs=crumbs_data_list,
        h1=esc(ctx.gettext(p["h1"])),
        byline_text=byline_text,
        dek=esc(fmt_page_alt(p["intro"])),
        ans_label=quick_title,
        answer=fmt_page_alt(p["quick"]),
        intro_ps=[],
        body="\n\n".join(body_sections),
        faq_items=faq_tr,
        free_cta=free_cta,
        checked_text=checked_note_text(long_date(ALT_MODIFIED, locale=locale, ctx=ctx) if ALT_MODIFIED else _(p.get("checked", ALT_CHECKED)), locale=locale, ctx=ctx),
        more_guides=loc_best,
        more_comparisons=loc_mm_vs,
        more_blog=loc_blog,
    )

    ld = [
        article_ld(_(p["title"]), ALT_MODIFIED),
        crumb_ld(hub, _(p["topic"]), path, locale=locale),
        {"@context": "https://schema.org", "@type": "ItemList", "name": _(p["topic"]),
         "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": tools_tr[k]["name"]} for i, k in enumerate(order)]},
        faq_ld(faq_tr),
    ]

    if locale != "en" and ctx.translated_count == 0:
        return None, None

    return path, page(_(p["title"]), _(p["description"]), path, "article", ld, main,
                      lang=i18n.get_locale(locale)["lang_tag"], alternates=alts, locale=locale, ctx=ctx)


def upgrade_tables(body):
    """Hand-written tables → the shared compare-table markup."""
    def fix(m):
        rows = re.findall(r"<tr>(.*?)</tr>", m.group(1), re.S)
        cells = [re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", r, re.S) for r in rows]
        if not cells:
            return m.group(0)
        header, data = cells[0], cells[1:]
        mm_first = len(header) > 1 and re.sub(r"<[^>]+>", "", header[1]).strip().startswith("MeetMouse")
        return "\n" + table(header, data, mm_first=mm_first,
                            mine_row=lambda r: re.sub(r"<[^>]+>", "", r[0]).strip().startswith("MeetMouse")) + "\n"
    return re.sub(r'\s*<div class="table-wrap">\s*<table>(.*?)</table>\s*</div>\s*', fix, body, flags=re.S)


def render_article(frag, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    env, tracker = i18n.create_tracked_jinja_env(locale)
    tmpl = env.get_template(frag.name)
    module = tmpl.make_module()
    front = module.meta
    rendered_body = tmpl.render()
    body = upgrade_tables(rendered_body)

    slug = front["path"]
    root = i18n.locale_root(locale)
    path = f"{root}{slug}" if root else slug
    norm_path = path.strip("/")
    alts = get_alternates(norm_path)

    art_fmt_vals = get_page_pricing_context()

    def fmt_art_meta(val):
        if isinstance(val, str) and "{" in val:
            try:
                return val.format(**art_fmt_vals)
            except (KeyError, ValueError):
                return val
        return val

    title = fmt_art_meta(front["title"])
    desc = fmt_art_meta(front["description"])
    h1 = front["h1"]
    dek = front["dek"]
    ans_label = front.get("answer_label", _("Quick answer"))
    answer = fmt_art_meta(front.get("answer", ""))
    intro_ps = [fmt_art_meta(x) for x in front.get("intro", [])]
    faq_items = [(fmt_art_meta(q), fmt_art_meta(a)) for q, a in front.get("faq", [])]
    checked = front.get("checked", _("October 2026"))
    date = front.get("date", "2026-10-20")
    kind = front.get("kind", "article")

    parent_url = f"/{root}alternatives/" if kind == "compare" else f"/{root}blog/"
    parent_label = _("Comparisons") if kind == "compare" else _("Blog")
    parent = (parent_url, parent_label)
    label = re.sub(r"<[^>]+>", "", h1).split(":")[0]

    byline_text = ""
    if kind == "article":
        byline_text = _("Founder, MeetMouse · Last checked {date}").format(date=long_date(date, locale=locale, ctx=ctx))

    parent_crumbs = [(parent_url, parent_label), ("", label)]
    loc_best, loc_mm_vs, loc_blog = more_links_data("/" + path, locale=locale, ctx=ctx)

    free_cta = get_free_cta(locale=locale, ctx=ctx)
    article_tmpl = env.get_template("article.html")
    main = article_tmpl.render(
        breadcrumbs=parent_crumbs,
        h1=h1,
        byline_text=byline_text,
        dek=dek,
        ans_label=ans_label,
        answer=answer,
        intro_ps=intro_ps,
        body=body.strip(),
        faq_items=faq_items,
        free_cta=free_cta,
        checked_text=checked_note_text(checked, locale=locale, ctx=ctx) if checked else "",
        more_guides=loc_best,
        more_comparisons=loc_mm_vs,
        more_blog=loc_blog,
    )
    ld = [article_ld(title, date), crumb_ld(parent, label, path, locale=locale)]
    if faq_items:
        ld.append(faq_ld(faq_items))

    if locale != "en" and tracker.translated_count == 0:
        return None, None

    return path, page(title, desc, path, "article", ld, main,
                      lang=i18n.get_locale(locale)["code"], alternates=alts, locale=locale, ctx=ctx)


def hub_list(links):
    return '    <ul class="hub-list">' + "".join(
        f'\n      <li><a href="{h}"><strong>{esc(t)}</strong><span>{esc(b)}</span></a></li>' for h, t, b in links) + "\n    </ul>"


def render_hub(path, title, desc, label, h1, dek, groups, locale="en", ctx=None):
    if ctx is None:
        ctx = i18n.TranslationContext(locale)
    _ = ctx.gettext

    norm_path = path.strip("/")
    alts = get_alternates(norm_path)
    blocks = []
    for heading, links in groups:
        blocks.append(f'    <section class="hub-group">\n      <h2>{heading}</h2>\n{hub_list(links)}\n    </section>')
    items = [l for _, ls in groups for l in ls]
    ld = [crumb_ld(None, label, path, locale=locale),
          {"@context": "https://schema.org", "@type": "ItemList", "name": title, "itemListElement": [
              {"@type": "ListItem", "position": i + 1, "name": t, "url": h if h.startswith("http") else BASE + h}
              for i, (h, t, _) in enumerate(items)]}]
    free_cta = get_free_cta(locale=locale, ctx=ctx)
    main_parts = [crumbs(None, label, locale=locale, ctx=ctx)]
    main_parts += [f"    <h1>{h1}</h1>", f'    <p class="dek">{dek}</p>'] + blocks + [cta(free_cta, locale=locale, ctx=ctx)]
    main = "\n\n".join(main_parts)
    return path.rstrip("/") + "/index", page(title, desc, path, "website", ld, main,
                                             lang=i18n.get_locale(locale)["lang_tag"], alternates=alts, locale=locale, ctx=ctx)


# ── utility & homepage generators ──────────────────────────────────────────────

def render_utility(template_name, path, locale="en"):
    env, tracker = i18n.create_tracked_jinja_env(locale)
    tmpl = env.get_template(template_name)
    alts = get_alternates(path)
    norm_path = path.strip("/")
    pfx = rel_prefix(norm_path)
    loc = i18n.get_locale(locale)
    root = f"/{loc['root'].strip('/')}" if loc.get("root") else ""

    ctx = {
        "lang": loc.get("lang_tag", "en"),
        "root": root,
        "rel_prefix": pfx,
        "hreflang_links": hreflang_links(alts),
        "lang_dropdown": lang_dropdown(norm_path, locale, alternates=alts),
        "resolve_url": lambda p: resolve_url(p, locale),
        "url": lambda p: resolve_url(p, locale),
        "price": "$20",
        "unlock_code": PRICES.meetmouse.unlock_code,
        "releases_url": "https://github.com/noahdevkagan/meeting-coach-releases/releases",
    }
    rendered = tmpl.render(**ctx)
    if locale != "en" and tracker.translated_count == 0:
        return None
    return rendered


def render_home(locale="en"):
    loc = i18n.get_locale(locale)
    root = loc["root"].lstrip("/")
    path = root
    norm_path = path
    alts = get_alternates(norm_path)
    canonical_url = f"{BASE}{loc['root']}/" if loc["root"] else f"{BASE}/"

    env, tracker = i18n.create_tracked_jinja_env(locale)
    tmpl = env.get_template("home.html")

    pfx = rel_prefix(norm_path)

    ctx = {
        "lang": loc.get("lang_tag", "en"),
        "root": loc["root"],
        "rel_prefix": pfx,
        "canonical_url": canonical_url,
        "hreflang_links": hreflang_links(alts),
        "lang_dropdown": lang_dropdown(norm_path, locale, alternates=alts),
        "buy_form": buy_form(locale=locale),
        "resolve_url": lambda p: resolve_url(p, locale),
        "url": lambda p: resolve_url(p, locale),
        "price": "$20",
        "unlock_code": PRICES.meetmouse.unlock_code,
        "releases_url": "https://github.com/noahdevkagan/meeting-coach-releases/releases",
    }
    out = tmpl.render(**ctx)
    if locale != "en" and tracker.translated_count == 0:
        return None, None
    key = f"{root}/index" if root else "index"
    return key, out


def llms_txt():
    head_txt = (DOCS / "llms.txt").read_text().split("\n## Product")[0].rstrip()
    def sec(title, links):
        return f"## {title}\n\n" + "\n".join(f"- [{t}]({h if h.startswith('http') else BASE + h}): {b}" for h, t, b in links)

    return "\n\n".join([
        head_txt,
        "## Product\n\n- [MeetMouse for Mac](https://meetmouse.com/): Free on-device meeting notes (transcript, summary, key takeaways, next steps), live coaching, pricing, and download.\n- [Changelog](https://meetmouse.com/changelog): Every release in plain language.",
        sec("Guides: best meeting tool by use case", [("/best/", "All guides", "Hub of honest picks per job.")] + BEST_LINKS),
        sec("Comparisons", [("/alternatives/", "All comparisons", "Every MeetMouse-vs and head-to-head page.")] + MM_VS + X_VS_Y),
        sec("Blog", BLOG),
        sec("Also by the same maker", [RHINO]),
    ]) + "\n"


def update_redirects():
    redirects_path = DOCS / "_redirects"
    if redirects_path.exists():
        existing = redirects_path.read_text(encoding="utf-8")
        if REDIRECTS_MARKER in existing:
            static_part = existing.split(REDIRECTS_MARKER)[0].rstrip()
        else:
            static_part = existing.rstrip()
    else:
        static_part = "# Cloudflare Pages redirects."

    lines = [static_part, "", REDIRECTS_MARKER]
    for loc_key, loc in i18n.LOCALES.items():
        root = loc["root"].strip("/")
        if root:
            if not is_page_available("", loc_key):
                lines.append(f"/{root}    /       302")
                lines.append(f"/{root}/   /       302")

    content = "\n".join(lines) + "\n"
    redirects_path.write_text(content, encoding="utf-8")


# ── build ────────────────────────────────────────────────────────────────────

def build():
    pages = {}

    for loc_key, loc in i18n.LOCALES.items():
        ctx = i18n.TranslationContext(loc_key)

        # 1. Best guides
        for p in BEST:
            if not is_page_available(p["slug"], loc_key):
                continue
            k, v = render_best(p, locale=loc_key, ctx=ctx)
            if k and v:
                pages[k] = v

        # 2. Compare structured pages
        for p in COMPARE:
            if not is_page_available(p["slug"], loc_key):
                continue
            k, v = render_compare(p, locale=loc_key, ctx=ctx)
            if k and v:
                pages[k] = v

        # 3. Alternatives blog roundups
        for p in ALT_PAGES:
            if not is_page_available("blog/" + p["slug"], loc_key):
                continue
            k, v = render_alternatives(p, locale=loc_key, ctx=ctx)
            if k and v:
                pages[k] = v

        # 4. Long-form HTML articles
        for slug, frag in ARTICLE_SLUGS:
            if not is_page_available(slug, loc_key):
                continue
            k, v = render_article(frag, locale=loc_key, ctx=ctx)
            if k and v:
                pages[k] = v

        # 5. Homepage
        if is_page_available("", loc_key):
            k_home, v_home = render_home(locale=loc_key)
            if k_home and v_home:
                pages[k_home] = v_home

        # 6. Utility pages
        for util in ["404", "thanks", "appsumo"]:
            if not is_page_available(util, loc_key):
                continue
            root = loc["root"].lstrip("/")
            p_util = f"{root}/{util}" if root else util
            res = render_utility(f"{util}.html", p_util, locale=loc_key)
            if res is not None:
                pages[p_util] = res

        # 7. Hubs (rendered if translations exist for that locale)
        root = loc["root"].lstrip("/")
        hub_prefix = f"{root}/" if root else ""
        _ = ctx.gettext

        loc_best = [(f"/{root}/" + p["slug"].lstrip("/") if root else "/" + p["slug"], _(p["label"]), _(p["blurb"])) for p in BEST]
        loc_mm_vs_articles = [(f"/{root}/" + h.lstrip("/") if root else h, _(t), _(b)) for h, t, b in MM_VS_ARTICLES]
        loc_mm_vs_compare = [(f"/{root}/" + p["slug"].lstrip("/") if root else "/" + p["slug"], "MeetMouse vs " + (p.get("competitor") or ""), _(p["blurb"])) for p in COMPARE]
        loc_mm_vs = loc_mm_vs_articles + loc_mm_vs_compare
        loc_blog = [(f"/{root}/" + h.lstrip("/") if root else h, _(t), _(b)) for h, t, b in BLOG]
        loc_x_vs_y = [(f"/{root}/" + h.lstrip("/") if root else h, _(t), _(b)) for h, t, b in X_VS_Y]

        if loc_key == "en" or is_page_available("best", loc_key):
            k_best, v_best = render_hub(
                f"{hub_prefix}best/",
                _("Best AI Meeting Tools by Use Case (2026) — MeetMouse"),
                _("The best AI notetaker or meeting coach for your job — sales, law, recruiting, consulting, coaching, founders, managers, financial advisors, Zoom and Mac. Honest picks, competitors included."),
                _("Guides"),
                _("The best meeting tools, by who you are"),
                _("A lawyer protecting privilege, a rep trying to close and a manager running 1:1s shouldn't buy the same thing. So I wrote a guide for each. Yes, I make MeetMouse, and it shows up in all of them. It doesn't win all of them, and each page tells you when something else is better, including the free stuff."),
                [
                    (_("By job"), loc_best),
                    (_("Looking for dictation instead?"), [(RHINO_GUIDES[0], _(RHINO_GUIDES[1]), _("Same rules, for Mac dictation apps. Rhino Voice is mine too."))])
                ],
                locale=loc_key, ctx=ctx
            )
            pages[k_best] = v_best

        if loc_key == "en" or is_page_available("alternatives", loc_key):
            k_alt, v_alt = render_hub(
                f"{hub_prefix}alternatives/",
                _("MeetMouse vs Granola, Fathom, Otter & More (2026) — Comparisons"),
                _("MeetMouse compared to Granola, Fathom, Otter, Fireflies, Poised, tl;dv, Gong, Zoom AI Companion and MacWhisper — plus honest head-to-heads between the notetakers themselves."),
                _("Comparisons"),
                _("MeetMouse vs everything else"),
                _("Every comparison I've written. The MeetMouse ones say when the other tool is the better pick. The head-to-heads between other tools are for when you've already decided you want a notetaker and just need to pick one."),
                [
                    (_("MeetMouse vs"), loc_mm_vs),
                    (_("Head-to-heads"), loc_x_vs_y),
                    (_("Alternatives"), [l for l in loc_blog if "alternatives" in l[0]])
                ],
                locale=loc_key, ctx=ctx
            )
            pages[k_alt] = v_alt

        if loc_key == "en" or is_page_available("blog", loc_key):
            all_guides_text = _("All guides")
            all_guides_desc = _("Every best-for guide.")
            all_comps_text = _("All comparisons")
            all_comps_desc = _("Every MeetMouse-vs and head-to-head page.")
            best_link = f"/{root}/best/" if root else "/best/"
            alt_link = f"/{root}/alternatives/" if root else "/alternatives/"

            k_blog, v_blog = render_hub(
                f"{hub_prefix}blog/",
                _("Blog — MeetMouse"),
                _("Honest writing about meeting tools by Noah Kagan, the guy who makes MeetMouse. Including the parts where competitors win."),
                _("Blog"),
                _("Blog"),
                _("Honest writing about meeting tools, by me, Noah — the guy who makes MeetMouse. Including the parts where competitors win."),
                [
                    (_("Posts"), loc_blog),
                    (_("Guides"), loc_best[:3] + [(best_link, all_guides_text, all_guides_desc)]),
                    (_("Comparisons"), loc_mm_vs[:4] + [(alt_link, all_comps_text, all_comps_desc)])
                ],
                locale=loc_key, ctx=ctx
            )
            pages[k_blog] = v_blog

    update_redirects()
    (DOCS / "lang.js").write_text((ROOT / "lang.js").read_text(encoding="utf-8"), encoding="utf-8")
    files = {DOCS / (k + ".html"): v for k, v in pages.items()}
    files[DOCS / "llms.txt"] = llms_txt()
    return files


# Served by the web-share Worker (web-share/wrangler.toml routes), not docs/.
WORKER_ROUTES = {"/get"}


def check_links(files):
    bad = []
    known = {"/", "/br/"} | {"/" + str(p.relative_to(DOCS).with_suffix("")).replace("\\", "/") for p in DOCS.rglob("*.html")}
    known |= {"/" + str(p.relative_to(DOCS)) for p in DOCS.rglob("*") if p.is_file()}
    known |= {"/" + str(p.parent.relative_to(DOCS)) + "/" for p in DOCS.rglob("index.html")}
    known |= {"/" + str(f.relative_to(DOCS).with_suffix("")) for f in files} | {"/" + str(f.parent.relative_to(DOCS)) + "/" for f in files}
    known |= WORKER_ROUTES

    # 1. Internal link target existence and valid ld+json
    for f, text in files.items():
        if f.suffix != ".html":
            continue
        for h in re.findall(r'href="(/[^"#?]*)"', text):
            if h not in known and h.rstrip("/") not in known and (h + "/") not in known:
                bad.append(f"{f.relative_to(REPO)} → {h}")
        for m in re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, re.S):
            try:
                json.loads(m)
            except Exception as e:
                bad.append(f"{f.relative_to(REPO)} invalid ld+json: {e}")
        if re.search(r"<(strong|em|b|i)\s*/>|(?<!<)/(strong|em|b|i)>", text):
            bad.append(f"{f.relative_to(REPO)} has malformed inline HTML tags")

    # 2. Every best page must disclose the maker's own pick
    for p in BEST:
        if not any(pk.get("mine") for pk in p["picks"]):
            bad.append(f"{p['slug']}: no pick marked mine")

    # 3. 1-to-1 parity between English and Portuguese content pages
    en_content = set(
        [p["slug"] for p in BEST]
        + [p["slug"] for p in COMPARE]
        + ["blog/" + p["slug"] for p in ALT_PAGES]
        + [slug for slug, _ in ARTICLE_SLUGS]
    )
    for ep in en_content:
        pt_target = DOCS / f"br/{ep}.html"
        if pt_target not in files and not pt_target.exists():
            bad.append(f"Target Portuguese file missing from build: {pt_target}")

    # 4. Reciprocal hreflang verification
    for f, text in files.items():
        if f.suffix != ".html":
            continue
        alts = re.findall(r'<link rel="alternate" hreflang="([^"]+)" href="https://meetmouse.com(/[^"]*)"', text)
        rel_f = f.relative_to(DOCS)
        my_clean = ("" if rel_f == Path("index.html")
                    else "br" if rel_f == Path("br/index.html")
                    else str(rel_f.parent) if rel_f.name == "index.html"
                    else str(rel_f.with_suffix("")))
        expected_alts = get_alternates(my_clean)
        if expected_alts:
            expected_set = set(expected_alts)
            actual_set = set((l, h) for l, h in alts if l != "x-default")
            if actual_set != expected_set:
                bad.append(f"{f.relative_to(REPO)} hreflang mismatch: actual {actual_set} != expected {expected_set}")

    return bad


def main():
    files = build()
    bad = check_links(files)
    if "--check" in sys.argv:
        stale = [str(f.relative_to(REPO)) for f, t in files.items() if not f.exists() or f.read_text() != t]
        if not (DOCS / "lang.js").exists() or (DOCS / "lang.js").read_text(encoding="utf-8") != (ROOT / "lang.js").read_text(encoding="utf-8"):
            stale.append(str((DOCS / "lang.js").relative_to(REPO)))
        if stale:
            print("Stale built files (run python3 site/build.py):", file=sys.stderr)
            for s in stale:
                print(f"  {s}", file=sys.stderr)
        if bad:
            print("Link/schema issues:", file=sys.stderr)
            for b in bad:
                print(f"  {b}", file=sys.stderr)
        if stale or bad:
            sys.exit(1)
        print(f"OK: {len(files)} content pages verified.")
        return

    for f, text in files.items():
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    print(f"Wrote {len(files)} content pages to docs/.")
    if bad:
        print("Link issues found:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
