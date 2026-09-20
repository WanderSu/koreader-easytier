#!/usr/bin/env python3
"""打 Release 资产：easytier.koplugin.zip（插件本体 + 说明文档）。

    python tools/pack-release.py                # 生成 out/easytier.koplugin.zip
    python tools/pack-release.py --verify <zip> # 校验 zip 的完整性、内容与版本号
"""

import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLUGIN = os.path.join(ROOT, "easytier.koplugin")
DOCS = ("README.md",)
OUT = os.path.join(ROOT, "out", "easytier.koplugin.zip")

# 这些文件绝不能进包（历史遗留：插件曾经带过一套英文翻译层）
FORBIDDEN = ("easytier.koplugin/et_i18n.lua", "easytier.koplugin/README.en.md")


def build():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(PLUGIN)):
            path = os.path.join(PLUGIN, name)
            if os.path.isfile(path):
                z.write(path, "easytier.koplugin/" + name)
        for doc in DOCS:
            path = os.path.join(ROOT, doc)
            if os.path.isfile(path):
                z.write(path, "easytier.koplugin/" + doc)
    return OUT


def verify(path):
    ok = True
    with zipfile.ZipFile(path) as z:
        bad = z.testzip()
        print("完整性:", "OK" if bad is None else ("损坏于 " + str(bad)))
        ok = bad is None
        for info in z.infolist():
            print("   %-38s %7d 字节" % (info.filename, info.file_size))
        names = z.namelist()
        for need in ("easytier.koplugin/main.lua", "easytier.koplugin/et_proc.lua",
                     "easytier.koplugin/_meta.lua", "easytier.koplugin/README.md"):
            if need not in names:
                print("!! 缺少", need)
                ok = False
        for forbidden in FORBIDDEN:
            if forbidden in names:
                print("!! 不该出现在包里：", forbidden)
                ok = False
        meta = "easytier.koplugin/_meta.lua"
        if meta in names:
            for line in z.read(meta).decode("utf-8").splitlines():
                if "version" in line:
                    print("插件版本:", line.strip())
                    break
    return ok


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--verify":
        sys.exit(0 if verify(sys.argv[2]) else 1)
    if len(sys.argv) >= 2 and sys.argv[1] == "--verify":
        sys.exit(0 if verify(OUT) else 1)
    packed = build()
    print("已生成 %s（%d 字节）" % (packed, os.path.getsize(packed)))
    print("内容:")
    for name in zipfile.ZipFile(packed).namelist():
        print("   " + name)
