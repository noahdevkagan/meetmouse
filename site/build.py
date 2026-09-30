#!/usr/bin/env python3
"""Build every MeetMouse content page from one template.

    python3 site/build.py          # write docs/**
    python3 site/build.py --check  # fail if docs/ is stale or links are broken

Sources:
  site/content/best.py     /best/* guides (structured)
  site/content/compare.py  structured "MeetMouse vs X" pages
  site/articles/*.html     freeform posts and older comparisons (front matter + body)
  site/content/links.py    the one list of pages; hubs, "more" blocks, llms.txt read it

The homepage, changelog (scripts/build-changelog.py), 404, thanks and appsumo
pages are hand-written and not touched. Shared CSS lives in docs/site.css.
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
sys.path.insert(0, str(ROOT / "content"))

from best import BEST  # noqa: E402
from compare import COMPARE  # noqa: E402
from links import BLOG, MM_VS_ARTICLES, RHINO, RHINO_GUIDES, X_VS_Y  # noqa: E402

esc = html.escape
OG_ALT = "MeetMouse: coached live, nothing leaves your Mac. $20 once, macOS, on-device."

BEST_LINKS = [("/" + p["slug"], p["label"], p["blurb"]) for p in BEST]
MM_VS = MM_VS_ARTICLES + [("/" + p["slug"], "MeetMouse vs " + p["competitor"], p["blurb"]) for p in COMPARE]
COMPARISONS = MM_VS + X_VS_Y


# ── chrome ───────────────────────────────────────────────────────────────────

def buy_form(compact=False):
    cls, btn, label = (("buy-form buy-form-compact", "button button-compact", "Buy — $20") if compact
                       else ("buy-form", "button", "Buy MeetMouse — $20"))
    return f"""<form class="{cls}" action="https://www.paypal.com/cgi-bin/webscr" method="post">
      <input type="hidden" name="cmd" value="_xclick">
      <input type="hidden" name="business" value="paypal@okdork.com">
      <input type="hidden" name="item_name" value="MeetMouse for Mac">
      <input type="hidden" name="amount" value="20.00">
      <input type="hidden" name="currency_code" value="USD">
      <input type="hidden" name="no_shipping" value="1">
      <input type="hidden" name="return" value="https://meetmouse.com/thanks.html">
      <input type="hidden" name="cancel_return" value="https://meetmouse.com/">
      <button class="{btn}" type="submit">{label}</button>
    </form>"""


HEADER = f"""  <a class="skip-link" href="#main">Skip to content</a>
  <header class="site-header">
    <a class="brand" href="/" aria-label="MeetMouse home">
      <span class="mark"><img src="/icon.png" alt=""></span>
      <span>MeetMouse</span>
    </a>
    <nav aria-label="Main navigation">
      <a href="/best/">Guides</a>
      <a href="/alternatives/">Comparisons</a>
      <a href="/blog/">Blog</a>
      {buy_form(compact=True)}
    </nav>
  </header>"""

FOOTER = f"""  <footer>
    <span>MeetMouse</span>
    <a href="mailto:support@meetmouse.com">support@meetmouse.com</a>
    <a href="/best/">Meeting tool guides</a>
    <a href="/alternatives/">Comparisons</a>
    <a href="/blog/">Blog</a>
    <a href="/changelog">Changelog</a>
    <a href="https://github.com/noahdevkagan/meeting-coach-releases/releases">Releases on GitHub</a>
    <a href="{RHINO[0]}">Also by me: Rhino Voice, private Mac dictation</a>
  </footer>"""


def head(title, desc, path, og_type, ld):
    url = f"{BASE}/{path}"
    lds = "\n".join('<script type="application/ld+json">' + json.dumps(b, ensure_ascii=False) + "</script>" for b in ld)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<meta name="description" content="{esc(desc)}">
<link rel="canonical" href="{url}">
<link rel="icon" type="image/png" href="/icon.png">
<meta property="og:type" content="{og_type}">
<meta property="og:url" content="{url}">
<meta property="og:title" content="{esc(title)}">
<meta property="og:description" content="{esc(desc)}">
<meta property="og:image" content="{BASE}/og.png">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta property="og:image:alt" content="{OG_ALT}">
<meta name="twitter:card" content="summary_large_image">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Geist:wght@400..800&family=Geist+Mono:wght@500..700&display=swap">
<link rel="stylesheet" href="/site.css">
{lds}
</head>"""


def page(title, desc, path, og_type, ld, main):
    return (head(title, desc, path, og_type, ld) + '\n<body>\n<div class="doc-page">\n' + HEADER
            + '\n  <main class="doc" id="main">\n' + main + "\n  </main>\n" + FOOTER + "\n</div>\n</body>\n</html>\n")


# ── shared blocks ────────────────────────────────────────────────────────────

def crumbs(parent, label):
    items = [("/", "MeetMouse")] + ([parent] if parent else [])
    out = "".join(f'<a href="{h}">{esc(t)}</a><span aria-hidden="true">/</span>' for h, t in items)
    return f'    <nav class="breadcrumb" aria-label="Breadcrumb">{out}<span>{esc(label)}</span></nav>'


def crumb_ld(parent, label, path):
    items = [("MeetMouse", f"{BASE}/")] + ([(parent[1], BASE + parent[0])] if parent else []) + [(label, f"{BASE}/{path}")]
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


def faq_block(faq):
    if not faq:
        return ""
    items = "".join(f"\n        <div><dt>{q}</dt><dd>{a}</dd></div>" for q, a in faq)
    return f'    <section>\n      <h2>Questions</h2>\n      <dl class="faq">{items}\n      </dl>\n    </section>'


def cta(body, heading="Try MeetMouse"):
    return f'    <section class="doc-cta">\n      <h2>{heading}</h2>\n      <p>{body}</p>\n      {buy_form()}\n    </section>'


def checked_note(month, legal=False):
    extra = " And I'm not your lawyer, doctor or compliance officer." if legal else ""
    return (f'    <p class="checked-note">I checked prices and features for the tools here in {month}. '
            f"This stuff changes constantly, so double-check before you buy.{extra}</p>")


def more_links(current):
    def ul(links):
        return "<ul>" + "".join(f'<li><a href="{h}">{esc(t)}</a></li>' for h, t, _ in links if h != current) + "</ul>"
    return f"""    <nav class="more-links" aria-label="More">
      <h2>More guides</h2>
      {ul(BEST_LINKS)}
      <h2>Comparisons</h2>
      {ul(MM_VS)}
      <h2>From the blog</h2>
      {ul(BLOG)}
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

GUIDES = ("/best/", "Guides")
COMPARE_HUB = ("/alternatives/", "Comparisons")
BLOG_HUB = ("/blog/", "Blog")


def render_best(p):
    path = p["slug"]
    out = [crumbs(GUIDES, p["label"]), f"    <h1>{p['headline']}</h1>", f'    <p class="dek">{p["dek"]}</p>',
           answer_box("TL;DR", p["short_answer"], [f"<strong>{k}:</strong> {v}" for k, v in p["short_picks"]]),
           table(["App", "Best for", "Price", "Stays on your Mac"],
                 [[pk["name"] + (" (mine)" if pk.get("mine") else ""), pk["best_for"], pk["price"], pk["local"]] for pk in p["picks"]],
                 caption="The picks at a glance", mine_row=lambda r: r[0].endswith("(mine)"))]
    for h, ps in p["intro"]:
        out.append(section(h, paras(ps)))
    for i, pk in enumerate(p["picks"], 1):
        badge = '<span class="mine-badge">mine</span>' if pk.get("mine") else ""
        meta = "".join(f"<div><dt>{k}</dt><dd>{v}</dd></div>" for k, v in
                       (("Best for", pk["best_for"]), ("Price", pk["price"]), ("Where your meeting is processed", pk["where"])))
        link = ""
        if pk.get("url"):
            ext = pk["url"].startswith("http")
            text = "See what MeetMouse does" if pk["url"] == "/" else f"Visit {pk['name']}"
            link = f'\n      <p><a class="inline-link" href="{pk["url"]}"' + (' rel="noopener"' if ext else "") + f">{text}</a></p>"
        out.append(f'    <section class="pick">\n      <h2>{i}. {pk["name"]}{badge}</h2>\n      <dl class="pick-meta">{meta}</dl>\n'
                   + paras(pk["body"]) + link + "\n    </section>")
    out.append(section("My pick", paras(p["verdict"])))
    out.append(section("What I'd do today", '      <ol class="today">' + "".join(f"<li>{s}</li>" for s in p["today"]) + "</ol>"))
    out += [faq_block(p["faq"]), cta(p["cta_body"]), checked_note(p["checked"], legal=True), more_links("/" + path)]
    ld = [crumb_ld(GUIDES, p["label"], path),
          {"@context": "https://schema.org", "@type": "ItemList", "name": p["label"],
           "itemListElement": [{"@type": "ListItem", "position": i + 1, "name": pk["name"]} for i, pk in enumerate(p["picks"])]},
          faq_ld(p["faq"])]
    return path, page(p["title"], p["description"], path, "article", ld, "\n\n".join(out))


def render_compare(p):
    path, them = p["slug"], p["competitor"]
    label = f"MeetMouse vs {them}"
    out = [crumbs(COMPARE_HUB, label), f"    <h1>{p['headline']}</h1>", f'    <p class="dek">{p["dek"]}</p>',
           answer_box("The short answer", p["short_answer"],
                      [f"<strong>Pick {them} if</strong> {p['pick_them']}", f"<strong>Pick MeetMouse if</strong> {p['pick_mm']}"]),
           table(["", "MeetMouse", them], p["rows"], caption=f"MeetMouse vs {them} at a glance", mm_first=True)]
    for h, ps in p["sections"]:
        out.append(section(h, paras(ps)))
    out += [faq_block(p["faq"]),
            cta("$20 once, no subscription and no account. If it doesn't earn its keep, email me inside 30 days and I'll refund you."),
            checked_note(p["checked"]), more_links("/" + path)]
    ld = [crumb_ld(COMPARE_HUB, label, path), faq_ld(p["faq"])]
    return path, page(p["title"], p["description"], path, "article", ld, "\n\n".join(out))


def upgrade_tables(body):
    """Hand-written tables → the shared compare-table markup."""
    def fix(m):
        rows = re.findall(r"<tr>(.*?)</tr>", m.group(1), re.S)
        cells = [re.findall(r"<t[hd][^>]*>(.*?)</t[hd]>", r, re.S) for r in rows]
        header, data = cells[0], cells[1:]
        mm_first = len(header) > 1 and re.sub(r"<[^>]+>", "", header[1]).strip() == "MeetMouse"
        return "\n" + table(header, data, mm_first=mm_first,
                            mine_row=lambda r: re.sub(r"<[^>]+>", "", r[0]).strip().startswith("MeetMouse")) + "\n"
    return re.sub(r'\s*<div class="table-wrap">\s*<table>(.*?)</table>\s*</div>\s*', fix, body, flags=re.S)


def render_article(frag):
    raw = frag.read_text()
    front = json.loads(re.match(r"<!--meta\n(.*?)\n-->\n", raw, re.S).group(1))
    body = upgrade_tables(raw[raw.index("-->\n") + 4:])
    path = front["path"]
    parent = COMPARE_HUB if front["kind"] == "compare" else BLOG_HUB
    label = re.sub(r"<[^>]+>", "", front["h1"]).split(":")[0]
    intro = "\n".join(f"    <p>{p}</p>" for p in front["intro"])
    out = [crumbs(parent, label), f"    <h1>{front['h1']}</h1>", f'    <p class="dek">{front["dek"]}</p>',
           answer_box(front["answer_label"], front["answer"])]
    if intro:
        out.append(intro)
    out += [body.strip(), faq_block(front["faq"]),
            cta("$20 once, no subscription and no account. If it doesn't earn its keep, email me inside 30 days and I'll refund you."),
            checked_note(front["checked"]), more_links("/" + path)]
    ld = [article_ld(front["title"], front["date"]), crumb_ld(parent, label, path)] + ([faq_ld(front["faq"])] if front["faq"] else [])
    return path, page(front["title"], front["description"], path, "article", ld, "\n\n".join(out))


def hub_list(links):
    return '    <ul class="hub-list">' + "".join(
        f'\n      <li><a href="{h}"><strong>{esc(t)}</strong><span>{esc(b)}</span></a></li>' for h, t, b in links) + "\n    </ul>"


def render_hub(path, title, desc, label, h1, dek, groups):
    blocks = []
    for heading, links in groups:
        blocks.append(f'    <section class="hub-group">\n      <h2>{heading}</h2>\n{hub_list(links)}\n    </section>')
    items = [l for _, ls in groups for l in ls]
    ld = [crumb_ld(None, label, path),
          {"@context": "https://schema.org", "@type": "ItemList", "name": title, "itemListElement": [
              {"@type": "ListItem", "position": i + 1, "name": t, "url": h if h.startswith("http") else BASE + h}
              for i, (h, t, _) in enumerate(items)]}]
    main = "\n\n".join([crumbs(None, label), f"    <h1>{h1}</h1>", f'    <p class="dek">{dek}</p>'] + blocks + [
        cta("$20 once. No subscription, no account, and your meetings stay on your Mac. Try it for 30 days; if it's not worth it, email me and I'll refund you.")])
    return path.rstrip("/") + "/index", page(title, desc, path, "website", ld, main)


def llms_txt():
    head_txt = (DOCS / "llms.txt").read_text().split("\n## Product")[0].rstrip()
    def sec(title, links):
        return f"## {title}\n\n" + "\n".join(f"- [{t}]({h if h.startswith('http') else BASE + h}): {b}" for h, t, b in links)
    return "\n\n".join([
        head_txt,
        "## Product\n\n- [MeetMouse for Mac](https://meetmouse.com/): What it does, how the live coaching overlay works, pricing, and download.\n- [Changelog](https://meetmouse.com/changelog): Every release in plain language.",
        sec("Guides: best meeting tool by use case", [("/best/", "All guides", "Hub of honest picks per job.")] + BEST_LINKS),
        sec("Comparisons", [("/alternatives/", "All comparisons", "Every MeetMouse-vs and head-to-head page.")] + MM_VS + X_VS_Y),
        sec("Blog", BLOG),
        sec("Also by the same maker", [RHINO]),
    ]) + "\n"


# ── build ────────────────────────────────────────────────────────────────────

def build():
    pages = dict(render_best(p) for p in BEST)
    pages.update(render_compare(p) for p in COMPARE)
    for frag in sorted((ROOT / "articles").glob("*.html")):
        k, v = render_article(frag)
        pages[k] = v
    pages.update([
        render_hub("best/", "Best AI Meeting Tools by Use Case (2026) — MeetMouse",
                   "The best AI notetaker or meeting coach for your job — sales, law, recruiting, consulting, coaching, founders, managers, financial advisors, Zoom and Mac. Honest picks, competitors included.",
                   "Guides", "The best meeting tools, by who you are",
                   "A lawyer protecting privilege, a rep trying to close and a manager running 1:1s shouldn't buy the same thing. So I wrote a guide for each. Yes, I make MeetMouse, and it shows up in all of them. It doesn't win all of them, and each page tells you when something else is better, including the free stuff.",
                   [("By job", BEST_LINKS), ("Looking for dictation instead?", [(RHINO_GUIDES[0], RHINO_GUIDES[1], "Same rules, for Mac dictation apps. Rhino Voice is mine too.")])]),
        render_hub("alternatives/", "MeetMouse vs Granola, Fathom, Otter & More (2026) — Comparisons",
                   "MeetMouse compared to Granola, Fathom, Otter, Fireflies, Poised, tl;dv, Gong, Zoom AI Companion and MacWhisper — plus honest head-to-heads between the notetakers themselves.",
                   "Comparisons", "MeetMouse vs everything else",
                   "Every comparison I've written. The MeetMouse ones say when the other tool is the better pick. The head-to-heads between other tools are for when you've already decided you want a notetaker and just need to pick one.",
                   [("MeetMouse vs", MM_VS), ("Head-to-heads", X_VS_Y), ("Alternatives", [l for l in BLOG if "alternatives" in l[0]])]),
        render_hub("blog/", "Blog — MeetMouse", "Honest writing about meeting tools by Noah Kagan, the guy who makes MeetMouse. Including the parts where competitors win.",
                   "Blog", "Blog",
                   "Honest writing about meeting tools, by me, Noah — the guy who makes MeetMouse. Including the parts where competitors win.",
                   [("Posts", BLOG), ("Guides", BEST_LINKS[:3] + [("/best/", "All guides", "Every best-for guide.")]),
                    ("Comparisons", MM_VS[:4] + [("/alternatives/", "All comparisons", "Every MeetMouse-vs and head-to-head page.")])]),
    ])
    files = {DOCS / (k + ".html"): v for k, v in pages.items()}
    files[DOCS / "llms.txt"] = llms_txt()
    return files


def check_links(files):
    bad = []
    known = {"/"} | {"/" + str(p.relative_to(DOCS).with_suffix("")).replace("\\", "/") for p in DOCS.rglob("*.html")}
    known |= {"/" + str(p.relative_to(DOCS)) for p in DOCS.rglob("*") if p.is_file()}
    known |= {"/" + str(p.parent.relative_to(DOCS)) + "/" for p in DOCS.rglob("index.html")}
    known |= {"/" + str(f.relative_to(DOCS).with_suffix("")) for f in files} | {"/" + str(f.parent.relative_to(DOCS)) + "/" for f in files}
    for f, text in files.items():
        for h in re.findall(r'href="(/[^"#?]*)"', text):
            if h not in known and h.rstrip("/") not in known:
                bad.append(f"{f.relative_to(REPO)} → {h}")
        for m in re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, re.S):
            json.loads(m)
    # Every best page must disclose the maker's own pick.
    for p in BEST:
        if not any(pk.get("mine") for pk in p["picks"]):
            bad.append(f"{p['slug']}: no pick marked mine")
    return bad


def main():
    files = build()
    bad = check_links(files)
    if "--check" in sys.argv:
        stale = [str(f.relative_to(REPO)) for f, t in files.items() if not f.exists() or f.read_text() != t]
        if stale:
            bad.append("stale (run python3 site/build.py): " + ", ".join(stale))
        sitemap = (DOCS / "sitemap.xml").read_text()
        for f in files:
            if f.suffix == ".html":
                rel = f.relative_to(DOCS)
                url = f"{BASE}/{rel.parent}/" if rel.name == "index.html" else f"{BASE}/{rel.with_suffix('')}"
                if f"<loc>{url}</loc>" not in sitemap:
                    bad.append(f"not in sitemap: {url}")
    else:
        for f, t in files.items():
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text(t)
        subprocess.run([sys.executable, str(REPO / "scripts" / "build-sitemap.py")], check=True)
        print(f"built {len(files)} files")
    if bad:
        print("\n".join(bad))
        sys.exit(1)


if __name__ == "__main__":
    main()
