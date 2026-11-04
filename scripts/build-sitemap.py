#!/usr/bin/env python3
"""Regenerate docs/sitemap.xml from the HTML files in docs/.

Pages containing a noindex robots meta are skipped. URLs use the site's
clean-URL scheme (Cloudflare Pages serves /foo for foo.html, /dir/ for
dir/index.html); lastmod comes from each file's last git commit.

Run directly, or let scripts/build-changelog.py invoke it — the release
ritual already runs that before every tag.
"""
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DOCS = REPO / "docs"
OUT = DOCS / "sitemap.xml"
BASE = "https://meetmouse.com"

NOINDEX = re.compile(r'<meta[^>]+robots[^>]+noindex', re.IGNORECASE)
HREFLANG = re.compile(r'<link rel="alternate" hreflang="([^"]+)" href="([^"]+)">')

# Ownership-verification stubs Google and Bing ask you to host. They are not
# pages, they carry no content, and listing them invites a thin-content crawl.
SKIP = re.compile(r'^(google[0-9a-f]+|BingSiteAuth)\.html$', re.IGNORECASE)


def url_for(path: Path) -> str:
    rel = path.relative_to(DOCS)
    if rel.name == "index.html":
        parent = rel.parent.as_posix()
        return f"{BASE}/" if parent == "." else f"{BASE}/{parent}/"
    return f"{BASE}/{rel.with_suffix('').as_posix()}"


def lastmod(path: Path) -> str:
    out = subprocess.run(
        ["git", "log", "-1", "--format=%cs", "--", str(path)],
        capture_output=True, text=True, cwd=REPO,
    ).stdout.strip()
    return out  # empty for untracked files → tag omitted


def main() -> None:
    entries = []
    for path in sorted(DOCS.rglob("*.html")):
        if SKIP.match(path.name):
            continue
        if NOINDEX.search(path.read_text(errors="ignore")):
            continue
        text = path.read_text(errors="ignore")
        mod = lastmod(path)
        mod_tag = f"<lastmod>{mod}</lastmod>" if mod else ""
        # Language versions (hreflang) declared in the page head, repeated here for crawlers.
        alts = "".join(f'<xhtml:link rel="alternate" hreflang="{l}" href="{h}"/>' for l, h in HREFLANG.findall(text))
        entries.append(f"  <url><loc>{url_for(path)}</loc>{mod_tag}{alts}</url>")

    page = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
        + "\n".join(entries)
        + "\n</urlset>\n"
    )
    if "--check" in sys.argv:
        if not OUT.exists() or OUT.read_text() != page:
            sys.exit("docs/sitemap.xml is stale — run: python3 scripts/build-sitemap.py")
        print(f"sitemap: docs/sitemap.xml is current ({len(entries)} URLs)")
        return
    OUT.write_text(page)
    print(f"wrote {OUT.relative_to(REPO)} ({len(entries)} URLs)")


if __name__ == "__main__":
    main()
