#!/usr/bin/env python3
"""App translations (app/Madeira/Localizable.xcstrings).

SwiftUI looks up every literal Text/Button/Label/Toggle/Section/... title in the string
catalog, so the app shows German, Spanish, Korean, Brazilian Portuguese or Russian when the
device uses one, and English otherwise (a text the catalog lacks stays English).

Checks: the catalog is in the app's resources with its languages; every key is still a
literal in the app's Swift (so a changed English text is noticed); every key has all five
languages; links, line breaks and trailing spaces survive translation. A text with
interpolations is keyed with %@ for each one (only String interpolations are translated
this way); its translations use %1$@, %2$@... so the words can move.
"""
from pathlib import Path
import json, re, sys

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
failures = 0


def check(condition, label):
    global failures
    print(('PASS: ' if condition else 'FAIL: ') + label)
    if not condition:
        failures += 1


catalog = json.loads((app / 'Localizable.xcstrings').read_text(encoding='utf-8'))
project = (app.parent / 'Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
languages = ['de', 'es', 'ko', 'pt-BR', 'ru']

check(project.count('A1009C03 /* Localizable.xcstrings in Resources */') == 2 and
      project.count('A2009C03 /* Localizable.xcstrings */') == 3, 'the catalog is in the app resources')
regions = re.search(r'knownRegions = \((.*?)\);', project, re.S)
check(regions is not None and all(l in regions.group(1) for l in ['de', 'es', 'ko', '"pt-BR"', 'ru']), 'the project knows the languages')
check(catalog.get('sourceLanguage') == 'en', 'English is the source language')

# The calls whose first argument SwiftUI reads as a LocalizedStringKey.
pattern = re.compile(r'\b(?:Text|Button|Label|Toggle|Section|Picker|navigationTitle|LabeledContent|TextField|Link|NavigationLink|'
                     r'Stepper|Menu|ShareLink|alert|confirmationDialog|SecureField|ContentUnavailableView|DisclosureGroup)'
                     r'\(\s*"((?:[^"\\]|\\.)*)"')
literals = set()
for swift in app.glob('*.swift'):
    for m in pattern.finditer(swift.read_text(encoding='utf-8')):
        text = re.sub(r'\\\([^()"]*\)', '%@', m.group(1))
        literals.add(re.sub(r'\\(["\\nt\'])', lambda x: {'n': '\n', 't': '\t'}.get(x.group(1), x.group(1)), text))

strings = catalog['strings']
stale = [k for k in strings if k not in literals]
check(not stale, 'every translated text is still in the app' + (f' (stale: {stale[:5]})' if stale else ''))
missing = [(k, l) for k, v in strings.items() for l in languages
           if not v.get('localizations', {}).get(l, {}).get('stringUnit', {}).get('value')]
check(not missing, 'every text has all five languages' + (f' (missing: {missing[:5]})' if missing else ''))
broken = []
for k, v in strings.items():
    for l in languages:
        t = v['localizations'][l]['stringUnit']['value']
        if ('](' in k) != ('](' in t) or k.count('\n') != t.count('\n') or k.endswith(' ') != t.endswith(' ') or \
                sorted(re.findall(r'%(\d)\$@', t)) != [str(i + 1) for i in range(k.count('%@'))] or \
                t.count('%') != k.count('%@'):
            broken.append((k[:30], l))
check(not broken, 'links, line breaks and trailing spaces survive' + (f' ({broken[:5]})' if broken else ''))
check(len(strings) >= 600, f'{len(strings)} texts translated')

print('FAIL' if failures else 'PASS')
sys.exit(1 if failures else 0)
