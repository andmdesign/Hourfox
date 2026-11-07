#!/usr/bin/env python3
"""Собирает строки интерфейса из Sources и пишет Resources/<язык>.lproj/Localizable.strings.

Ключи — русские строки (так они и выглядят в коде). Переводы — Scripts/translations.json.
Если в коде появилась строка без перевода, скрипт остановится и покажет её.
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LANGS = ["en", "uk", "zh-Hans", "es", "pt-BR", "cs", "it"]
# Самоназвания языков и подписи, которые не переводятся.
IGNORE = {
    "Русский", "Українська",
    # Служебные слова умного ввода: их пишет пользователь, в интерфейсе их нет.
    "(?:м|мин|минут|минуты|минута|хв|хвилин|хвилини|хвилина|m|min)", "(?:ч|час|часа|часов|год|годин|години|година|h|hr)",
    "сегодня", "сьогодні", "завтра", "послезавтра", "післязавтра",
}
# Интерполяции, которые SwiftUI подставляет как целые числа (%lld), остальные — %@.
INT_EXPRS = {"open.count - 4", "notes.count - 4", "store.doneTasks.count"}


def literals(code):
    """Строковые литералы Swift с учётом вложенных скобок в \\( … )."""
    i = 0
    while True:
        i = code.find('"', i)
        if i < 0:
            return
        j, out = i + 1, []
        while j < len(code) and code[j] != '"':
            if code.startswith("\\(", j):
                depth, k = 1, j + 2
                while k < len(code) and depth:
                    depth += {"(": 1, ")": -1}.get(code[k], 0)
                    k += 1
                expr = code[j + 2:k - 1]
                out.append("%lld" if expr in INT_EXPRS else "%@")
                j = k
            elif code.startswith("\\u{00A0}", j):
                out.append("\u00a0"); j += 8
            elif code[j] == "\\":
                out.append({"n": "\n"}.get(code[j + 1], code[j + 1])); j += 2
            else:
                out.append(code[j]); j += 1
        yield "".join(out)
        i = j + 1


keys = []
for name in sorted(os.listdir(os.path.join(ROOT, "Sources/Hourfox"))):
    if not name.endswith(".swift") or name == "Debug.swift":
        continue
    for line in open(os.path.join(ROOT, "Sources/Hourfox", name), encoding="utf-8"):
        code = line.strip()
        if code.startswith("//") or "NSLog(" in code:
            continue
        for lit in literals(line):
            if re.search(r"[А-Яа-яЁё]", lit) and lit not in IGNORE and lit not in keys:
                keys.append(lit)

table = json.load(open(os.path.join(ROOT, "Scripts/translations.json"), encoding="utf-8"))
missing = [k for k in keys if k not in table]
if missing:
    sys.exit("Нет перевода:\n" + "\n".join(repr(k) for k in missing))


def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


for lang in LANGS:
    lines = [f"/* Hourfox — {lang}. Сгенерировано Scripts/l10n.py, править translations.json. */", ""]
    lines += [f'"{esc(k)}" = "{esc(table[k][lang])}";' for k in keys]
    d = os.path.join(ROOT, "Resources", f"{lang}.lproj")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "Localizable.strings"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(f"{len(keys)} строк × {len(LANGS)} языков")
