#!/usr/bin/env python3
"""Check explicit app UI localization calls against the compiled English catalog."""
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[2]
entry = re.compile(r'^\s*("(?:[^"\\]|\\.)*"): ("(?:[^"\\]|\\.)*"),$', re.M)
catalog = {json.loads(k): json.loads(v) for k, v in entry.findall((root / 'Localization.swift').read_text())}
call = re.compile(r'L10n\.(?:text|format)\(("(?:[^"\\]|\\.)*")(?=[,)])')
# Lumen components translate their title/detail inputs internally.
component = re.compile(r'\b(?:SettingRow|LumenPanel|MicroText|Pill|DetailPair|SearchBox|EmptyState|NoticeBar|PageHeader|PageFooter)\(\s*("(?:[^"\\]|\\.)*")|\b(?:title|subtitle|detail|leading|placeholder|text):\s*("(?:[^"\\]|\\.)*")')
missing = []
unlocalized = []
# Check raw UI sinks too: checking only L10n calls misses entire new surfaces.
raw_ui = re.compile(r'(?:\b(?:Text|Button|Toggle|Label|Picker|Section)|\.(?:help|navigationTitle|accessibilityLabel))\(\s*("(?:[^"\\]|\\.)*")|(?:\b(?:title|placeholderString|toolTip|messageText|informativeText)\s*=|(?:withTitle|accessibilityDescription):)\s*("(?:[^"\\]|\\.)*")')
for path in root.glob('*.swift'):
    if path.name == 'Localization.swift':
        continue
    source = path.read_text()
    for match in raw_ui.finditer(source):
        literal = match[1] or match[2]
        if re.search('[\u4e00-\u9fff]', literal):
            unlocalized.append(f'{path.name}:{source[:match.start()].count(chr(10)) + 1}: {literal}')
    for match in component.finditer(source):
        literal = match[1] or match[2]
        try:
            key = json.loads(literal)
        except json.JSONDecodeError:
            continue
        if re.search('[\u4e00-\u9fff]', key) and key not in catalog:
            missing.append(f'{path.name}: {key}')
    for match in call.finditer(source):
        try:
            key = json.loads(match[1])
        except json.JSONDecodeError:
            continue  # Swift interpolation: app-owned parts have explicit format calls.
        if re.search('[\u4e00-\u9fff]', key) and key not in catalog:
            missing.append(f'{path.name}: {key}')
for key, value in catalog.items():
    if key in {'中文', '简体中文'}:
        continue  # Native language name in the language picker.
    assert not re.search('[\u4e00-\u9fff]', value), f'Chinese in English catalog: {key}'
    assert sorted(re.findall(r'%\{\d+\}', key)) == sorted(re.findall(r'%\{\d+\}', value)), f'Placeholder mismatch: {key}'
assert not unlocalized, 'Unlocalized UI literals:\n' + '\n'.join(unlocalized)
assert not missing, 'Missing translations:\n' + '\n'.join(missing)
print(f'PASS: {len(catalog)} English entries; UI call coverage and placeholders verified')
