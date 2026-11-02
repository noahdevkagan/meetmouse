#!/usr/bin/env python3
"""Translate untranslated messages in a locale messages.po using local Ollama.

Usage:
  python3 scripts/translate_catalog.py [locale] [options]

Examples:
  python3 scripts/translate_catalog.py pt_BR
  python3 scripts/translate_catalog.py es --model gemma3:4b
  python3 scripts/translate_catalog.py pt-BR --batch-size 10
"""
import argparse
from datetime import datetime
import json
import re
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE_DIR = ROOT / "site"
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

from babel.messages import pofile
from babel.messages.mofile import write_mo
import i18n

OLLAMA_URL = "http://127.0.0.1:11434/api/generate"
DEFAULT_MODEL = "gemma3:4b"


def get_git_user_translator() -> str:
    try:
        name = subprocess.check_output(["git", "config", "user.name"], text=True).strip()
        email = subprocess.check_output(["git", "config", "user.email"], text=True).strip()
        if name and email:
            return f"{name} <{email}>"
    except Exception:
        pass
    return ""


def update_header_comment(comment: str, author_str: str = "", year: str = "2026") -> str:
    if not comment:
        return comment
    comment = comment.replace("ORGANIZATION", "MeetMouse")
    if author_str:
        if "FIRST AUTHOR <EMAIL@ADDRESS>" in comment:
            comment = re.sub(r"FIRST AUTHOR <EMAIL@ADDRESS>, \d{4}", f"{author_str}, {year}", comment)
        elif author_str not in comment:
            lines = comment.splitlines()
            idx = -1
            for i, line in enumerate(lines):
                if "FIRST AUTHOR" in line or (line.startswith("#") and ("@" in line or "<" in line)):
                    idx = i
            if idx != -1:
                lines.insert(idx + 1, f"# {author_str}, {year}.")
            else:
                if lines and lines[-1].strip() == "#":
                    lines.insert(-1, f"# {author_str}, {year}.")
                else:
                    lines.append(f"# {author_str}, {year}.")
            comment = "\n".join(lines)
    return comment





# ── Translation Rules ────────────────────────────────────────────────────────

GENERIC_CRITICAL_RULES = """1. Target language: natural {target_lang} ({target_code}).
2. ALWAYS preserve all placeholders like {{price}}, {{otter_price}}, {{granola_price}}, {{fireflies_price}}, {{fathom_price}}, {{team}}, {{annual}}, {{them}}, {{checked}}, {{name}}, {{date}}, {{month}}, {{extra}}, {{incumbent}}, {{lang}}, etc. EXACTLY character for character without changing, removing, or dropping them.
3. ALWAYS preserve all HTML tags (<a href="...">, <strong>, <em>, <br>, <code>, <dl>, <dt>, <dd>, etc.) exactly without changing attributes or tag structure.
4. Keep technical and product terms natural (Mac, macOS, Apple Silicon, MeetMouse, Granola, Fathom, Otter, Fireflies, tl;dv, bot, offline, etc.).
5. Return ONLY a valid JSON object with the exact same numerical keys ("0", "1", ...). Do not wrap in markdown or explanatory text."""

LOCALE_RULES = {
    "pt-BR": """6. ALWAYS use variable placeholders for prices and translate pricing units to Brazilian Portuguese:
   - /user/mo or /seat/mo -> /usuário/mês (e.g. {price}/usuário/mês)
   - /mo or /month -> /mês (e.g. {price}/mês)
   - /yr or /year -> /ano (e.g. {annual}/ano)
   - /user -> /usuário
   - {price} once for unlimited -> {price} uma única vez para uso ilimitado
   - NEVER invent or hardcode static dollar numbers if the source uses a placeholder like {price}, {granola_price}, {otter_price}, etc.""",
    "es": """6. ALWAYS use variable placeholders for prices and translate pricing units to Spanish:
   - /user/mo or /seat/mo -> /usuario/mes (e.g. {price}/usuario/mes)
   - /mo or /month -> /mes (e.g. {price}/mes)
   - /yr or /year -> /año (e.g. {annual}/año)
   - /user -> /usuario
   - {price} once for unlimited -> {price} una sola vez para ilimitado
   - NEVER invent or hardcode static dollar numbers if the source uses a placeholder like {price}, {granola_price}, {otter_price}, etc.""",
}


def build_prompt(sample: dict[str, str], loc: dict) -> str:
    target_lang = loc.get("english_name") or loc.get("name") or "the target language"
    target_code = loc.get("code") or loc.get("po_name") or ""

    generic_rules = GENERIC_CRITICAL_RULES.format(
        target_lang=target_lang,
        target_code=target_code,
    )
    rules_parts = [generic_rules]
    specific = LOCALE_RULES.get(loc.get("code", ""))
    if specific:
        rules_parts.append(specific)
    else:
        rules_parts.append(
            f"6. Keep all price placeholders intact and translate pricing units naturally into {target_lang}."
        )

    rules_text = "\n".join(rules_parts)
    return f"""You are a professional software translator for macOS developer tools.
Translate this JSON mapping of English strings into natural {target_lang}.

CRITICAL RULES:
{rules_text}

JSON to translate:
{json.dumps(sample, ensure_ascii=False, indent=2)}
"""


def call_ollama(prompt: str, model: str = DEFAULT_MODEL, timeout: int = 180) -> str:
    payload = {
        "model": model,
        "prompt": prompt,
        "format": "json",
        "stream": False,
        "options": {
            "temperature": 0.2,
        }
    }
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data.get("response", "")
    except Exception as e:
        print(f"Ollama call failed or timed out: {e}")
        return ""


def translate_batch(batch: list[str], loc: dict, model: str = DEFAULT_MODEL, timeout: int = 120) -> dict[str, str]:
    sample = {str(i): text for i, text in enumerate(batch)}
    prompt = build_prompt(sample, loc)
    raw = call_ollama(prompt, model=model, timeout=timeout)
    try:
        data = json.loads(raw)
        results = {}
        for k, text in sample.items():
            if k in data and isinstance(data[k], str):
                trans = data[k].strip()
                # Validate placeholder integrity
                src_vars = set(re.findall(r"\{[a-zA-Z0-9_]+\}", text))
                tgt_vars = set(re.findall(r"\{[a-zA-Z0-9_]+\}", trans))
                if src_vars.issubset(tgt_vars):
                    results[text] = trans
                else:
                    print(f"Warning: missing placeholders in {text!r} -> {trans!r}")
        return results
    except Exception as e:
        print(f"Error parsing batch response: {e}")
        return {}


def main():
    parser = argparse.ArgumentParser(description="Translate catalog strings using local Ollama.")
    parser.add_argument("locale", nargs="?", default="pt_BR", help="Locale to translate (default: pt_BR)")
    parser.add_argument("-l", "--locale-opt", dest="locale_opt", help="Locale option alias")
    parser.add_argument("-f", "--file", dest="po_file", help="Path to specific PO file to translate")
    parser.add_argument("-m", "--model", default=DEFAULT_MODEL, help=f"Ollama model (default: {DEFAULT_MODEL})")
    parser.add_argument("-b", "--batch-size", type=int, default=8, help="Max items per batch (default: 8)")
    parser.add_argument("-c", "--max-chars", type=int, default=500, help="Max characters per batch (default: 500)")
    parser.add_argument("-t", "--timeout", type=int, default=180, help="Timeout in seconds (default: 180)")
    parser.add_argument("--dry-run", action="store_true", help="Plan batches without translating")
    args = parser.parse_args()

    if args.po_file:
        po_path = Path(args.po_file)
        if not po_path.is_absolute():
            po_path = ROOT / po_path
        # Infer locale from path if default
        raw_loc = args.locale_opt or args.locale
        for part in po_path.parts:
            if part in ("pt_BR", "pt-BR", "es", "en"):
                raw_loc = part
                break
    else:
        raw_loc = args.locale_opt or args.locale
        loc = i18n.get_locale(raw_loc)
        po_name = loc.get("po_name", raw_loc.replace("-", "_"))
        po_path = LOCALE_DIR / po_name / "LC_MESSAGES" / "messages.po"

    loc = i18n.get_locale(raw_loc)
    po_name = loc.get("po_name", raw_loc.replace("-", "_"))

    if not po_path.exists():
        sys.exit(f"PO file not found at {po_path}. Check locale or file path.")

    display_name = loc.get("name", raw_loc)
    print(f"Target locale: {po_name} ({display_name})")
    print(f"Using model:   {args.model}")
    print(f"Catalog file:  {po_path.relative_to(ROOT)}")

    with open(po_path, "rb") as f:
        cat = pofile.read_po(f)

    missing = [m for m in cat if m.id and (not m.string or m.fuzzy)]
    total_missing = len(missing)
    print(f"Loaded {len(cat)} messages. Untranslated / fuzzy: {total_missing}")

    if total_missing == 0:
        print(f"Catalog for {po_name} is already 100% translated!")
        return

    # Sort: short strings first, then medium, then long
    missing.sort(key=lambda m: len(m.id))

    batches = []
    curr = []
    curr_len = 0
    for m in missing:
        item_len = len(m.id)
        if curr and (len(curr) >= args.batch_size or curr_len + item_len > args.max_chars):
            batches.append(curr)
            curr = []
            curr_len = 0
        curr.append(m.id)
        curr_len += item_len
    if curr:
        batches.append(curr)

    print(f"Formed {len(batches)} batches.")

    if args.dry_run:
        print("Dry run completed.")
        return

    translated_count = 0
    for b_idx, batch in enumerate(batches, 1):
        t0 = time.time()
        translations = translate_batch(batch, loc, model=args.model, timeout=args.timeout)
        dur = time.time() - t0

        if not translations:
            print(f"Batch {b_idx} failed JSON parse, retrying items individually...")
            for text in batch:
                res = translate_batch([text], loc, model=args.model, timeout=args.timeout)
                if res:
                    translations.update(res)

        for text, trans in translations.items():
            if text in cat and trans:
                msg = cat[text]
                msg.string = trans
                msg.flags.discard("fuzzy")
                if "%" in text:
                    msg.flags.discard("python-format")
                    msg.flags.add("no-python-format")
                translated_count += 1

        print(f"[{b_idx}/{len(batches)}] Translated {len(translations)}/{len(batch)} in {dur:.1f}s ({translated_count}/{total_missing} total)")

        # Save checkpoint every batch with new translations
        if len(translations) > 0:
            cat.revision_date = datetime.now().astimezone()
            git_user = get_git_user_translator()
            if not cat.last_translator or "FULL NAME" in cat.last_translator:
                if git_user:
                    cat.last_translator = git_user
            if git_user and cat.header_comment:
                cat.header_comment = update_header_comment(cat.header_comment, git_user)
            elif cat.header_comment:
                cat.header_comment = update_header_comment(cat.header_comment)
            for m in cat:
                m.flags.discard("python-format")
                m.flags.discard("python-brace-format")
                if "%" in m.id:
                    m.flags.add("no-python-format")
            with open(po_path, "wb") as f:
                pofile.write_po(f, cat, sort_output=True)
            mo_path = po_path.with_suffix(".mo")
            with open(mo_path, "wb") as f:
                write_mo(f, cat)

    print(f"Finished translation for {po_name}! Total translated this run: {translated_count}")


if __name__ == "__main__":
    main()
