#!/usr/bin/env python3
"""列出插件里所有可翻译字符串（_(...) 里的内容），用于维护 et_i18n.lua 里的中文对照表。

    python tools/i18n_extract.py            # 列出所有条目
    python tools/i18n_extract.py --missing  # 只列出还没写进 et_i18n.lua 中文表的条目
"""
import re
import sys
import glob
import os

PLUGIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "easytier.koplugin")

# 匹配 _("...") / _([[ ... ]])，字符串里可以有转义
PAT = re.compile(r'_\(\s*("(?:[^"\\]|\\.)*"|\[\[(?:.|\n)*?\]\])')
CJK = re.compile(r'[\u3400-\u9fff\uf900-\ufaff]')
# et_i18n.lua 里的 ["English source"] = "中文" 对照
PAIR = re.compile(r'\[("(?:\\.|[^"\\])*")\]\s*=\s*("(?:\\.|[^"\\])*")')


def unescape(lit):
    if lit.startswith("[[") or lit.startswith("[="):
        return lit[lit.index("[") + 2: -2]
    body = lit[1:-1]
    return (body.replace('\\n', '\n').replace('\\t', '\t')
                .replace('\\"', '"').replace("\\\\", "\\"))


def collect():
    found = {}
    for path in sorted(glob.glob(os.path.join(PLUGIN, "*.lua"))):
        name = os.path.basename(path)
        if name == "et_i18n.lua":
            continue  # 表本身不是待翻译内容
        src = open(path, encoding="utf-8").read()
        for m in PAT.finditer(src):
            found.setdefault(unescape(m.group(1)), []).append(name)
    return found


def known_zh():
    """et_i18n.lua 里已收录的英文源串（表的键）"""
    path = os.path.join(PLUGIN, "et_i18n.lua")
    if not os.path.exists(path):
        return set()
    src = open(path, encoding="utf-8").read()
    return {unescape(m.group(1)) for m in PAIR.finditer(src)}


def main():
    entries = collect()
    only_missing = "--missing" in sys.argv
    zh_keys = known_zh()
    n = 0
    for idx, (s, files) in enumerate(sorted(entries.items()), 1):
        missing = s not in zh_keys
        if only_missing and not missing:
            continue
        n += 1
        flag = "MISSING" if missing else "ok     "
        print(f"{idx:4d}  {flag}  {s!r}   <- {', '.join(sorted(set(files)))}")
    print(f"\n共 {len(entries)} 条可翻译字符串，" + (f"其中 {n} 条缺中文" if only_missing else f"et_i18n 中文表覆盖 {len(zh_keys)} 条"))


if __name__ == "__main__":
    main()
