#!/usr/bin/env python3
"""把 i18n/zh.txt 中的译文套用到 Objective-C 源码里的界面字符串上。

用法:
    python3 scripts/zh_apply.py          # 就地套用译文
    python3 scripts/zh_apply.py --check  # 只检查是否还有可替换但未译的字符串

只改写 i18n/zh.txt 里出现过的、且与键完全相同的 C 字符串字面量（跳过注释、
日志调用和格式说明符不匹配的项），因此重复运行是幂等的：第二次运行会把
中文再当作文本来找，找不到英文键，源码保持不变。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TABLE = ROOT / "i18n" / "zh.txt"
# 只改界面层的字符串；数据层（备份清单键、日志、状态字符串）必须是英文。
TARGETS = ["main.m", "WQApps.m", "WQCache.m", "WQSharing.m", "WQPlistEditor.m",
           "WQHexViewer.m", "WQUI.m", "WQSQLiteViewer.m", "WQArchive.m", "WQAccess.m"]
# 会显示给用户的错误文本一并汉化；被测试断言的文案已同步改成译文。
LOG_CALLS = ("wq_log(", "NSLog(", "fprintf(", "printf(")
# 这些上下文里的字面量是磁盘目录名/比较基准，翻译会让逻辑失效。
COMPARE_PATTERN = re.compile(
    r"(isEqualToString|hasPrefix|hasSuffix|isEqual|caseInsensitiveCompare|compare"
    r"|stringByAppendingPathComponent|stringByAppendingString|lastPathComponent|pathExtension)\s*:\s*@?$")
# 这些不是界面文案：谓词、日期格式、机型营销名。
IGNORE = ("selected == YES", "yyyy-MM-dd HH.mm.ss", "en_US_POSIX", "android",
          "Archive",  # 默认压缩包文件名，会写进文件系统
          "New",      # 暂存目录名，用作 renameatx_np 的路径参数
          "Cancelled",  # 被测试断言的中止标记
          "rollback failed: ",  # 以 stringByAppendingString 拼接的片段，替换后不会回退
          "A–Z", "Z–A", "SQL", "android",  # 与译文相同，无需替换
          "Before restore", "<!DOCTYPE plist", "<plist")
IGNORE_PREFIX = ("iPhone",)
# 这些是日志/诊断文字（部分经 NSLog 之外的方式输出），保留英文。
IGNORE_KEYS = {
    "can't read %@ (%s)", "loaded %@%@ from the app", "no icon PNG in %@ (tried %@)",
    "iOS returned an icon", "finding app containers", "reading app names",
    "WQ full scan", "generation changed", "PRAGMA query_only = ON",
    "%s (errno %d)", "uid %d", "found by id in %.1f s", "full (%@)",
    "; %lu removed since the last scan", " (%lu no longer exist, skipped)",
    "cleanup failed", "no free name", "no bundle path in the app database",
    "SELECT count(*) FROM sqlite_master", "SELECT name, type FROM sqlite_master",
    "SELECT * FROM (%@) LIMIT %lu OFFSET %lu",
}

UNESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}


def unescape(body: str) -> str:
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c != "\\" or i + 1 >= len(body):
            out.append(c)
            i += 1
            continue
        nxt = body[i + 1]
        if nxt in UNESCAPES:
            out.append(UNESCAPES[nxt])
            i += 2
        elif nxt == "u" and i + 5 < len(body) and re.fullmatch(r"[0-9a-fA-F]{4}", body[i + 2:i + 6]):
            out.append(chr(int(body[i + 2:i + 6], 16)))
            i += 6
        else:
            out.append("\\" + nxt)
            i += 2
    return "".join(out)


def escape(text: str) -> str:
    out = []
    for c in text:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c == "\r":
            out.append("\\r")
        else:
            out.append(c)
    return "".join(out)


def load_table() -> dict:
    table = {}
    for number, line in enumerate(TABLE.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 2:
            raise SystemExit(f"{TABLE}:{number}: 需要两列（英文<TAB>中文）")
        source, target = fields
        if re.findall(r"%(?:\d+\$)?[-+0-9.*]*[a-zA-Z@]", source) != \
                re.findall(r"%(?:\d+\$)?[-+0-9.*]*[a-zA-Z@]", target):
            raise SystemExit(f"{TABLE}:{number}: 格式符不一致: {source!r} -> {target!r}")
        table[source] = target
    return table


def rewrite(path: Path, table: dict, pending: list) -> int:
    text = path.read_text(encoding="utf-8")
    out, i, changed = [], 0, 0
    while i < len(text):
        c = text[i]
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = len(text) if end < 0 else end
            out.append(text[i:end])
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = len(text) if end < 0 else end + 2
            out.append(text[i:end])
            i = end
            continue
        if c in "'" and (not out or not out[-1].endswith("@")):
            end = text.find("'", i + 1)
            end = len(text) if end < 0 else end + 1
            out.append(text[i:end])
            i = end
            continue
        if c == '"':
            j, parts = i + 1, []
            while j < len(text) and text[j] != '"':
                if text[j] == "\\" and j + 1 < len(text):
                    parts.append(text[j:j + 2])
                    j += 2
                    continue
                parts.append(text[j])
                j += 1
            raw = "".join(parts)
            close = j + 1
            # Objective-C 会把相邻字面量拼成一个字符串（"a" "b" 或 @"a" @"b"），
            # 合并后再查表，这样跨行写成的长句也能整体替换。
            while True:
                k = close
                while k < len(text) and text[k] in " \t\r\n":
                    k += 1
                if k < len(text) and text[k] == "@" and k + 1 < len(text) and text[k + 1] == '"':
                    k += 1
                if k >= len(text) or text[k] != '"':
                    break
                k += 1
                while k < len(text) and text[k] != '"':
                    if text[k] == "\\" and k + 1 < len(text):
                        raw += text[k:k + 2]
                        k += 2
                        continue
                    raw += text[k]
                    k += 1
                close = k + 1
            logical = unescape(raw)
            line_start = text.rfind("\n", 0, i) + 1
            prefix = "".join(out)[line_start:]
            in_log = any(call in prefix for call in LOG_CALLS) or "*summary" in prefix
            # 只检查紧邻的调用上下文（"..." 之前的 60 个字符）
            near = "".join(out)[-60:]
            if COMPARE_PATTERN.search(near) or "stringByAppendingPathComponent:@" in near \
                    or "stringByAppendingString:@" in near:
                in_log = True
            if logical in table and not in_log and logical not in IGNORE:
                out.append('"' + escape(table[logical]) + '"')
                changed += 1
                i = close
                continue
            if not in_log and not logical.startswith(IGNORE_PREFIX) \
                    and logical not in IGNORE and logical not in IGNORE_KEYS \
                    and re.search(r"[A-Za-z]{3,}", logical) and " " in logical.strip() \
                    and re.fullmatch(r"[ -~]+", logical) \
                    and not re.fullmatch(r"[a-z0-9_.\-/ ]+", logical) \
                    and not logical.startswith(("SELECT", "PRAGMA", "EXPLAIN", "WITH ")) \
                    and not re.match(r"^[a-z][a-z ]{1,24}: ", logical):
                pending.append(f"{path.name}: {logical[:70]}")
            out.append(text[i:close])
            i = close
            continue
        out.append(c)
        i += 1
    if changed:
        path.write_text("".join(out), encoding="utf-8")
    return changed


def main() -> int:
    table = load_table()
    pending: list = []
    total = 0
    for name in TARGETS:
        total += rewrite(ROOT / name, table, pending)
    if "--check" in sys.argv:
        for line in pending:
            print("未译:", line)
        print(f"未译字符串 {len(pending)} 条，本轮替换 {total} 处")
        return 1 if pending else 0
    print(f"已替换 {total} 处字符串")
    return 0


if __name__ == "__main__":
    sys.exit(main())
