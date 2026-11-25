#!/usr/bin/env python3
"""Checks Loam's string catalogs.

Every language in the Xcode project's knownRegions (besides English and Base) must have a
translation for every key, with every plural form that language needs and the same format
arguments as the English text. Adding a language is adding it to knownRegions and filling in
its column in Xcode's String Catalog editor; this check then lists whatever is still missing.

With --stringsdata DIR (a DerivedData folder after a build), it also lists strings the compiler
extracted from Loam's Swift code that the catalog doesn't have yet, so a new or changed
sentence can't ship untranslated.

    python3 scripts/check-localizations.py
    python3 scripts/check-localizations.py --stringsdata "$RUNNER_TEMP/DerivedData"
"""

import argparse
import json
import plistlib
import re
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = [ROOT / "Loam/Resources/Localizable.xcstrings", ROOT / "Loam/Resources/InfoPlist.xcstrings"]
PROJECT = ROOT / "Loam.xcodeproj/project.pbxproj"

# CLDR plural categories each language uses for whole numbers. Add a row with a new language.
PLURAL_FORMS = {
    "en": {"one", "other"},
    "pl": {"one", "few", "many", "other"},
    "de": {"one", "other"},
    "es": {"one", "many", "other"},
    "fr": {"one", "many", "other"},
    "it": {"one", "many", "other"},
    "pt": {"one", "many", "other"},
    "uk": {"one", "few", "many", "other"},
    "cs": {"one", "few", "many", "other"},
}

# The %#@name@ form comes first, or "%#@" would read as an object with the # flag.
SPECIFIER = re.compile(r"%#@(\w+)@|%(?:(\d+)\$)?[-+#0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])|%%")
KINDS = {"@": "object", "f": "double", "F": "double", "e": "double", "g": "double", "a": "double", "c": "char", "s": "cstring", "S": "cstring", "p": "pointer"}


def kind(conversion):
    return KINDS.get(conversion.lower() if conversion in "EGA" else conversion, "int")


def arguments(text, substitutions=None):
    """The format arguments in text, as a Counter of (position, kind)."""
    found = Counter()
    position = 0
    for match in SPECIFIER.finditer(text):
        name, explicit, _, conversion = match.groups()
        if match.group(0) == "%%":
            continue
        if name is not None:
            sub = (substitutions or {}).get(name)
            if sub is None:
                found[("?", "missing substitution " + name)] += 1
                continue
            position += 1
            found[(sub.get("argNum", position), kind(sub.get("formatSpecifier", "@")[-1]))] += 1
            continue
        position = int(explicit) if explicit else position + 1
        found[(position, kind(conversion))] += 1
    return found


def units(localization):
    """Every (label, text) a localization shows, with plural and device variations flattened."""
    if "stringUnit" in localization:
        yield "", localization["stringUnit"].get("value", ""), localization["stringUnit"].get("state")
    for group, cases in localization.get("variations", {}).items():
        for case, nested in cases.items():
            for label, text, state in units(nested):
                yield f"{group}.{case}{'.' + label if label else ''}", text, state


def plural_problems(localization, language, where):
    problems = []
    needed = PLURAL_FORMS.get(language)
    for name, sub in localization.get("substitutions", {}).items():
        problems += plural_problems(sub, language, f"{where} substitution {name}")
    plural = localization.get("variations", {}).get("plural")
    if plural is not None and needed is not None:
        missing = needed - set(plural)
        if missing:
            problems.append(f"{where}: missing plural forms {', '.join(sorted(missing))}")
    if plural is not None:
        # Xcode refuses to compile a plural whose forms never show the number.
        texts = [text for _, text, _ in units({"variations": {"plural": plural}})]
        if not any(SPECIFIER.search(text.replace("%%", "")) for text in texts):
            problems.append(f"{where}: no plural form shows the number; use separate keys instead")
    return problems


def languages():
    """Every language the project or a catalog has, so dropping one from knownRegions can't hide it."""
    text = PROJECT.read_text(encoding="utf-8")
    block = re.search(r"knownRegions = \((.*?)\);", text, re.S)
    regions = {region.strip().strip('"') for region in block.group(1).split(",") if region.strip()} if block else set()
    for path in CATALOGS:
        for entry in json.loads(path.read_text(encoding="utf-8")).get("strings", {}).values():
            regions.update(entry.get("localizations", {}))
    return sorted(regions - {"en", "Base"})


def check_catalog(path, required):
    catalog = json.loads(path.read_text(encoding="utf-8"))
    source = catalog.get("sourceLanguage", "en")
    problems = []
    for key, entry in catalog.get("strings", {}).items():
        if entry.get("shouldTranslate") is False or entry.get("extractionState") == "stale":
            continue
        localizations = entry.get("localizations", {})
        # The key is the format Swift passes in, so every language, English included, must take the
        # same arguments. A substitution that reads the wrong argument shows up as a type mismatch here.
        expected = Counter() if path.name == "InfoPlist.xcstrings" else arguments(key)
        for language in [source] + required:
            localization = localizations.get(language)
            where = f"{key!r} [{language}]"
            if localization is None:
                if language != source:
                    problems.append(f"{where}: not translated")
                continue
            problems += plural_problems(localization, language, where)
            subs = localization.get("substitutions")
            for name, sub in (subs or {}).items():
                for label, text, state in units(sub):
                    if state not in ("translated", None):
                        problems.append(f"{where} substitution {name} {label}: state is {state}")
            for label, text, state in units(localization):
                if state not in ("translated", None):
                    problems.append(f"{where} {label or 'value'}: state is {state}")
                found = arguments(text, subs)
                # A plural form may leave its number out ("one day"), but never adds or changes one.
                ok = not (found - expected) if label.startswith("plural.") else found == expected
                if not ok:
                    problems.append(f"{where} {label or 'value'}: arguments {dict(found)} don't match the key's {dict(expected)}")
    return catalog, problems


def read_stringsdata(path):
    raw = path.read_bytes()
    try:
        return json.loads(raw)
    except ValueError:
        return plistlib.loads(raw)


def extracted_keys(derived_data):
    """Keys the compiler extracted from Loam's own Swift files, by table."""
    keys = {}
    app_sources = str(ROOT / "Loam") + "/"
    for path in Path(derived_data).rglob("*.stringsdata"):
        data = read_stringsdata(path)
        source = str(data.get("source", ""))
        if source and not source.startswith(app_sources):
            continue
        for table, entries in data.get("tables", {}).items():
            for entry in entries:
                keys.setdefault(table, {}).setdefault(entry["key"], source)
    return keys


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stringsdata", metavar="DIR", help="DerivedData folder to compare extracted strings against")
    args = parser.parse_args()

    required = languages()
    if not required:
        print("error: no languages besides English in knownRegions or the catalogs")
        return 1
    problems = []
    catalogs = {}
    for path in CATALOGS:
        catalog, found = check_catalog(path, required)
        catalogs[path.stem] = catalog
        problems += [f"{path.name}: {problem}" for problem in found]

    if args.stringsdata:
        extracted = extracted_keys(args.stringsdata)
        if not extracted:
            problems.append(f"No .stringsdata for Loam's sources under {args.stringsdata}; is SWIFT_EMIT_LOC_STRINGS on?")
        localizable = catalogs["Localizable"]["strings"]
        for key, source in sorted(extracted.get("Localizable", {}).items()):
            if key not in localizable:
                where = Path(source).relative_to(ROOT) if source else "?"
                problems.append(f"Localizable.xcstrings: {key!r} from {where} is missing from the catalog")
        unused = sorted(set(localizable) - set(extracted.get("Localizable", {})))
        for key in unused:
            if localizable[key].get("extractionState") != "manual":
                print(f"warning: {key!r} is in Localizable.xcstrings but no Swift code uses it", file=sys.stderr)

    for problem in problems:
        print(f"error: {problem}")
    if problems:
        print(f"\n{len(problems)} localization problem(s). Languages checked: {', '.join(required) or 'none'}.")
        return 1
    print(f"Localizations OK for {', '.join(required) or 'no languages besides English'}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
