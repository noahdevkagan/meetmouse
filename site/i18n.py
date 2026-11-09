"""Internationalization (i18n) module for MeetMouse.

Powered by Babel and Jinja2 with standard GNU Gettext PO format.
Compatible with Crowdin:
  - Source template: site/locale/messages.pot
  - Target catalogs: site/locale/<lang>/LC_MESSAGES/messages.po
Missing or empty translations automatically fall back to the English source string.
"""
from pathlib import Path
import html
import sys

SITE_DIR = Path(__file__).resolve().parent
REPO_DIR = SITE_DIR.parent

# Ensure virtualenv packages (jinja2, babel) are accessible
for venv_path in [REPO_DIR / ".venv", SITE_DIR / ".venv"]:
    if venv_path.exists():
        site_pkgs = list(venv_path.glob("lib/python*/site-packages"))
        for sp in site_pkgs:
            if str(sp) not in sys.path:
                sys.path.insert(0, str(sp))

import jinja2
from babel.messages import pofile

LOCALE_DIR = SITE_DIR / "locale"
TEMPLATES_DIR = SITE_DIR / "templates"
ARTICLES_DIR = SITE_DIR / "articles"

LOCALES = {
    "en": {
        "code": "en",
        "lang_tag": "en",
        "root": "",
        "po_name": "en",
        "name": "English",
        "english_name": "English",
    },
    "pt-BR": {
        "code": "pt-BR",
        "lang_tag": "pt-BR",
        "root": "/br",
        "po_name": "pt_BR",
        "name": "Português",
        "english_name": "Brazilian Portuguese",
    },
    "es": {
        "code": "es",
        "lang_tag": "es",
        "root": "/es",
        "po_name": "es",
        "name": "Español",
        "english_name": "Spanish",
    },
}


ENGLISH_MONTHS = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December"
]


def format_long_date(iso: str, ctx=None) -> str:
    gettext = ctx.gettext if ctx else (lambda s: s)
    y, m, d = (int(x) for x in iso.split("-"))
    month_name = gettext(ENGLISH_MONTHS[m - 1])
    fmt = gettext("date_format_long")
    if not fmt or fmt == "date_format_long":
        fmt = "{month} {day}, {year}"
    return fmt.format(day=d, month=month_name, year=y)

_CATALOG_CACHE = {}


def get_locale(lang: str) -> dict:
    """Return locale configuration dict for a language code."""
    if not lang:
        return LOCALES["en"]
    norm = lang.replace("_", "-")
    for key, loc in LOCALES.items():
        if key.lower() == norm.lower() or loc["code"].lower() == norm.lower():
            return loc
    prefix = norm.split("-")[0].lower()
    for key, loc in LOCALES.items():
        if key.lower().startswith(prefix):
            return loc
    return {
        "code": lang,
        "lang_tag": lang,
        "root": f"/{norm.lower()}",
        "po_name": lang.replace("-", "_"),
        "name": lang,
        "english_name": lang,
    }


def locale_root(locale: str) -> str:
    """Return prefix path with trailing slash for localized URLs (or empty string for English).
    e.g. 'en' -> '', 'pt-BR' -> 'br/', 'es' -> 'es/'
    """
    loc = get_locale(locale)
    r = loc.get("root", "").strip("/")
    return (r + "/") if r else ""


def load_catalog(lang: str) -> dict:
    """Load PO translations for a given language code into a dictionary.

    Returns dict mapping source msgid -> translated msgstr.
    For 'en' or missing catalogs, returns an empty dict (falling back to msgid).
    """
    if lang in _CATALOG_CACHE:
        return _CATALOG_CACHE[lang]

    loc = get_locale(lang)
    po_name = loc.get("po_name", lang.replace("-", "_"))
    po_candidates = [
        LOCALE_DIR / po_name / "LC_MESSAGES" / "messages.po",
        LOCALE_DIR / lang.replace("-", "_") / "LC_MESSAGES" / "messages.po",
    ]

    translations = {}
    for po_file in po_candidates:
        if po_file.exists():
            with open(po_file, "rb") as f:
                cat = pofile.read_po(f)
                for msg in cat:
                    if msg.id and msg.string:
                        s = msg.string if isinstance(msg.string, str) else msg.string[0]
                        if s:
                            translations[msg.id] = s
            break

    _CATALOG_CACHE[lang] = translations
    return translations


_PO_CATALOG_CACHE: dict = {}


def get_po_catalog(lang: str):
    """Load and cache the raw Babel Catalog (with Message objects and locations)."""
    if lang in _PO_CATALOG_CACHE:
        return _PO_CATALOG_CACHE[lang]
    loc = get_locale(lang)
    po_name = loc.get("po_name", lang.replace("-", "_"))
    po_candidates = [
        LOCALE_DIR / po_name / "LC_MESSAGES" / "messages.po",
        LOCALE_DIR / lang.replace("-", "_") / "LC_MESSAGES" / "messages.po",
    ]
    for po_file in po_candidates:
        if po_file.exists():
            with open(po_file, "rb") as f:
                cat = pofile.read_po(f)
                _PO_CATALOG_CACHE[lang] = cat
                return cat
    return None


class TranslationTracker:
    """Tracks how many translated strings are actually retrieved from the catalog."""

    def __init__(self, catalog_or_locale):
        if isinstance(catalog_or_locale, dict):
            self.catalog = catalog_or_locale
            self.locale = None
        else:
            self.locale = str(catalog_or_locale)
            self.catalog = load_catalog(self.locale)
        self.translated_count = 0

    def gettext(self, msgid: str, **kwargs) -> str:
        if not msgid:
            return ""
        text = self.catalog.get(msgid) if (msgid in self.catalog and self.catalog[msgid]) else msgid
        if self.catalog.get(msgid):
            self.translated_count += 1
        if kwargs:
            try:
                return text.format(**kwargs)
            except (KeyError, IndexError, ValueError):
                return text
        return text

    def __call__(self, msgid: str, **kwargs) -> str:
        return self.gettext(msgid, **kwargs)

    def reset(self):
        self.translated_count = 0


TranslationContext = TranslationTracker


def get_translator(lang: str):
    """Return a gettext function that translates msgid with fallback to msgid."""
    catalog = load_catalog(lang)

    def _(msgid: str, **kwargs) -> str:
        if not msgid:
            return ""
        text = catalog.get(msgid) or msgid
        if kwargs:
            try:
                return text.format(**kwargs)
            except (KeyError, IndexError, ValueError):
                return text
        return text

    return _


def create_jinja_env(
    lang: str = "en",
    template_dir: Path = None,
    url_map: dict = None,
    tracker: TranslationTracker = None,
) -> jinja2.Environment:
    """Create a Jinja2 Environment configured with GNU Gettext translation callables.

    Any {{ _('English string') }} or {% trans %}English string{% endtrans %}
    will evaluate to the translation for `lang`, or fallback to English if missing.
    """
    if template_dir is not None:
        loader = jinja2.FileSystemLoader(str(template_dir))
    else:
        loader = jinja2.FileSystemLoader([str(TEMPLATES_DIR), str(ARTICLES_DIR), str(SITE_DIR)])
    env = jinja2.Environment(
        loader=loader,
        extensions=["jinja2.ext.i18n"],
        autoescape=False,
        trim_blocks=True,
        lstrip_blocks=True,
    )

    if tracker is not None:
        t = tracker.gettext
    else:
        t = get_translator(lang)

    def ngettext(singular, plural, n):
        return t(singular) if n == 1 else t(plural)

    env.install_gettext_callables(gettext=t, ngettext=ngettext, newstyle=False)

    loc = get_locale(lang)
    root = loc["root"]

    def resolve_url(path: str) -> str:
        try:
            import build
            return build.resolve_url(path, locale=lang)
        except (ImportError, AttributeError):
            if not path or not root:
                return path
            clean = path.strip("/")
            return root + ("/" + clean if clean else "") + ("/" if path.endswith("/") and clean else "")

    try:
        from pricing import PRICES
        mm_price = PRICES.meetmouse.price
        prices_obj = PRICES
    except ImportError:
        mm_price = "$20"
        prices_obj = {"meetmouse": {"price": "$20"}}

    env.globals.update(
        lang=loc["lang_tag"],
        lang_code=loc["code"],
        root=root,
        resolve_url=resolve_url,
        url=resolve_url,
        esc=html.escape,
        price=mm_price,
        prices=prices_obj,
    )
    return env


def create_tracked_jinja_env(
    lang: str = "en",
    template_dir: Path = None,
    url_map: dict = None,
) -> tuple[jinja2.Environment, TranslationTracker]:
    """Create a Jinja2 Environment with an attached TranslationTracker to count translated strings."""
    catalog = load_catalog(lang)
    tracker = TranslationTracker(catalog)
    env = create_jinja_env(lang, template_dir=template_dir, url_map=url_map, tracker=tracker)
    return env, tracker
