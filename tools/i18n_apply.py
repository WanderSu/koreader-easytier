#!/usr/bin/env python3
"""把插件源码里的中文字面量换成英文源串。

英文源串与中文的对应关系只维护一份：`easytier.koplugin/et_i18n.lua` 里的 zh 表
（`["English source"] = "中文"`）。本脚本读这张表，把它当作「中文 -> 英文」的反查表，
改写其它文件里的 `_("中文")`，并把 `require("gettext")` 换成 `require("et_i18n").tr`。

    python tools/i18n_apply.py           # 改写（原文件备份到 out/i18n-backup/）
    python tools/i18n_apply.py --check   # 只检查，不改写

改写后会列出没在表里找到的（含中文/全角标点的）字面量，有就说明表需要补。
"""
import os
import re
import sys
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "easytier.koplugin")
BACKUP = os.path.join(ROOT, "out", "i18n-backup")
I18N = os.path.join(PLUGIN, "et_i18n.lua")

CJK = re.compile(r'[\u3400-\u9fff\uf900-\ufaff\u3000-\u303f\uff00-\uffef]')
# _( "..." ) 或 _( [[ ... ]] )
CALL = re.compile(r'_\(\s*("(?:\\.|[^"\\])*"|\[=*\[(?:.|\n)*?\]=*\])')
PAIR = re.compile(r'\[("(?:\\.|[^"\\])*")\]\s*=\s*("(?:\\.|[^"\\])*")')
REQUIRE_OLD = 'local _ = require("gettext")'
REQUIRE_NEW = 'local _ = require("et_i18n").tr'


def lua_decode(lit):
    """把 Lua 字符串字面量（含引号）解成 python str"""
    if lit.startswith("["):
        eq = lit[1:lit.index("[")]
        body = lit[len(eq) + 2: -(len(eq) + 2)]
        return body
    body = lit[1:-1]
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            n = body[i + 1]
            mapping = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", '"': '"', "'": "'"}
            out.append(mapping.get(n, n))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def lua_encode(s):
    body = (s.replace("\\", "\\\\").replace('"', '\\"')
             .replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r"))
    return '"' + body + '"'


def load_pairs():
    src = open(I18N, encoding="utf-8").read()
    pairs = {}
    for m in PAIR.finditer(src):
        en, zh = lua_decode(m.group(1)), lua_decode(m.group(2))
        pairs[zh] = en
    return pairs


def main():
    check_only = "--check" in sys.argv
    zh2en = load_pairs()
    print(f"et_i18n.lua 里有 {len(zh2en)} 条中英对照")

    os.makedirs(BACKUP, exist_ok=True)
    total, leftovers = 0, []
    for name in sorted(os.listdir(PLUGIN)):
        if not name.endswith(".lua") or name == "et_i18n.lua":
            continue
        path = os.path.join(PLUGIN, name)
        src = open(path, encoding="utf-8").read()
        original = src
        replaced = 0

        def sub(m):
            nonlocal replaced
            lit = m.group(1)
            decoded = lua_decode(lit)
            if decoded in zh2en:
                replaced += 1
                # 注意：正则只匹配到 `_(` 和字面量本身，右括号在原文里，这里不能补
                return "_(" + lua_encode(zh2en[decoded])
            if CJK.search(decoded):
                leftovers.append((name, decoded))
            return m.group(0)

        src = CALL.sub(sub, src)
        if REQUIRE_OLD in src:
            src = src.replace(REQUIRE_OLD, REQUIRE_NEW)

        if replaced:
            total += replaced
            print(f"  {name}: 替换 {replaced} 处")
            if not check_only:
                shutil.copy2(path, os.path.join(BACKUP, name))
                open(path, "w", encoding="utf-8", newline="\n").write(src)
        elif src != original and not check_only:
            shutil.copy2(path, os.path.join(BACKUP, name))
            open(path, "w", encoding="utf-8", newline="\n").write(src)

    print(f"\n共替换 {total} 处字面量" + ("（--check，未写入）" if check_only else ""))
    if leftovers:
        print(f"\n未能在表里找到对应英文的字符串 {len(leftovers)} 条：")
        for name, s in leftovers:
            print(f"  {name}: {s!r}")
        return 1
    print("没有遗漏：所有中文串都能在 et_i18n.lua 的表中找到")
    return 0


if __name__ == "__main__":
    sys.exit(main())
