#!/usr/bin/env python3
"""剥离 HarmonyOS build-profile.json5 里的本机签名配置（signingConfigs）。

背景
----
DevEco Studio 每次执行「自动签名」（File > Project Structure > Signing Configs）
都会把本机证书路径和 keystore 口令写进 build-profile.json5。这些内容一旦入库：
  1. 泄露 keystore 口令（keyPassword / storePassword）；
  2. 绝对路径 /Users/<某人>/.ohos/config/... 在别人机器上不存在，clone 后构建失败。

本脚本供 pre-commit 钩子调用，把 signingConfigs 的内容替换为 []，
其余字段与注释保持原样（不做 JSON 重排，避免产生无关 diff）。

用法
----
    python3 scripts/strip-signing.py check < build-profile.json5
        含签名内容 -> 退出码 0；已干净 -> 退出码 1
    python3 scripts/strip-signing.py strip < build-profile.json5
        输出剥离后的内容到 stdout；解析失败 -> 退出码 2
    python3 scripts/strip-signing.py norm < build-profile.json5
        输出「归一化」内容（去掉字符串与注释之外的所有空白），用于判断两次改动
        是否只是格式重排（DevEco 保存时会把单行数组拆成多行）

说明
----
文件是 JSON5（带 // 注释、尾逗号），不能用 json 模块解析，
因此这里做逐字符扫描，跳过字符串字面量与注释后再定位 signingConfigs。
"""

import sys

TARGET_KEY = "signingConfigs"


def _read_string(text, start):
    """从 start（应为起始引号）读到字符串结束。返回 (结束下标, 原始内容)。"""
    i = start + 1
    n = len(text)
    buf = []
    while i < n:
        c = text[i]
        if c == "\\":
            buf.append(text[i:i + 2])
            i += 2
            continue
        if c == '"':
            return i + 1, "".join(buf)
        buf.append(c)
        i += 1
    return n, "".join(buf)


def _skip_ignorable(text, i):
    """跳过空白与注释（// 行注释、/* */ 块注释）。"""
    n = len(text)
    while i < n:
        c = text[i]
        if c in " \t\r\n":
            i += 1
        elif c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            break
    return i


def _match_bracket(text, start):
    """start 处为 '['，返回匹配 ']' 之后的下标。未闭合则抛 ValueError。"""
    i = start
    n = len(text)
    depth = 0
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '"':
            i, _ = _read_string(text, i)
            continue
        if c in "[{":
            depth += 1
        elif c in "]}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("signingConfigs 数组括号未闭合")


def find_signing_arrays(text):
    """返回 [(arr_start, arr_end), ...]，按出现顺序（前者含 '['，后者在 ']' 之后）。"""
    ranges = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            i = n if j < 0 else j + 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if c == '"':
            j, value = _read_string(text, i)
            if value == TARGET_KEY:
                # 键后面还有一个冒号： "signingConfigs" : [ ... ]
                k = _skip_ignorable(text, j)
                if k < n and text[k] == ":":
                    k = _skip_ignorable(text, k + 1)
                if k < n and text[k] == "[":
                    ranges.append((k, _match_bracket(text, k)))
            i = j
            continue
        i += 1
    return ranges


def has_material(text):
    """signingConfigs 数组里是否真有内容（忽略空白与注释）。"""
    for start, end in find_signing_arrays(text):
        inner = text[start + 1:end - 1]
        stripped = []
        k = 0
        while k < len(inner):
            nxt = _skip_ignorable(inner, k)
            if nxt > k:
                k = nxt
                continue
            stripped.append(inner[k])
            k += 1
        if "".join(stripped):
            return True
    return False


def strip(text):
    """把所有 signingConfigs 数组替换为 []，其余内容原样保留。"""
    out = text
    for start, end in reversed(find_signing_arrays(out)):
        out = out[:start] + "[]" + out[end:]
    return out


def normalize(text):
    """去掉字符串与注释之外的所有空白，用于比较「是否只是格式重排」。

    字符串与注释按原文保留 —— 它们的内容变了就算实质改动，不能当成噪声丢掉。
    """
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            j = n if j < 0 else j
            out.append(text[i:j])
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append(text[i:j])
            i = j
            continue
        if c == '"':
            j, _ = _read_string(text, i)
            out.append(text[i:j])
            i = j
            continue
        if not c.isspace():
            out.append(c)
        i += 1
    return "".join(out)


def main(argv):
    if len(argv) != 2 or argv[1] not in ("check", "strip", "norm"):
        sys.stderr.write(__doc__)
        return 2
    text = sys.stdin.read()
    try:
        if argv[1] == "check":
            return 0 if has_material(text) else 1
        sys.stdout.write(strip(text) if argv[1] == "strip" else normalize(text))
        return 0
    except ValueError as exc:
        sys.stderr.write("解析失败: %s\n" % exc)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
