#!/usr/bin/env python3
"""校验文档之间的相对链接是否都指向真实存在的文件。

    python scripts/check_docs.py

**为什么需要它**

仓库里的文档互相引用得很密（README ↔ `docs/` ↔ 各模块 README ↔ `shared/`），
而**移动或改名一个文件不会让任何引用报错** —— 它只会让那句「详见 xxx.md」
指向空气。文档照常读得通，坏掉的只是信任：读者点进去发现没有，就再也不会
相信文档里的第二句话。

这不是假设。本项目 README 里「详细开发计划见团队计划文档」这句，
在计划文档真正入库之前挂了很多天，谁都没发现。

所以把「链接有效」变成一条会红的检查。它与 `sync_assets.py --check` 是同一类：
**把静默失效提前到提交之前。**

只检查 Markdown 链接 `[文字](路径)`，**不检查正文里反引号包起来的路径** ——
后者大量是示意性的（例如「放到 `app/assets/…` 下」），逐个要求存在会误报，
而**带误报的检查最终一定会被关掉**。那比没有检查更糟。
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]

#: 不扫描的目录：依赖与构建产物，里面的 .md 不是本项目的文档。
_SKIP_PARTS = frozenset(
    {
        "node_modules",
        ".venv",
        "site-packages",
        ".dart_tool",
        ".pytest_cache",
        "build",
        "dist",
    }
)

#: `[说明](目标)`。目标里不允许有空白，因此含空格的标题不会被误当一个链接。
_LINK = re.compile(r"\[([^\]]*)\]\(([^)\s]+)\)")

#: 这些目标不是文件，跳过。
_EXTERNAL_PREFIXES = ("http://", "https://", "mailto:", "#")


def documents() -> list[pathlib.Path]:
    found: list[pathlib.Path] = []
    for path in sorted(ROOT.rglob("*.md")):
        if set(path.relative_to(ROOT).parts) & _SKIP_PARTS:
            continue
        found.append(path)
    return found


def main() -> int:
    docs = documents()
    broken: list[tuple[pathlib.Path, str]] = []
    checked = 0

    for doc in docs:
        text = doc.read_text(encoding="utf-8", errors="replace")
        for match in _LINK.finditer(text):
            target = match.group(2)
            if target.startswith(_EXTERNAL_PREFIXES):
                continue
            # 锚点部分不参与文件存在性判断
            path_part = target.split("#", 1)[0]
            if not path_part:
                continue
            checked += 1
            if not (doc.parent / path_part).resolve().exists():
                broken.append((doc.relative_to(ROOT), target))

    if broken:
        print(f"\n{len(broken)} 条相对链接指向不存在的文件（共检查 {checked} 条）：\n", file=sys.stderr)
        for doc, target in broken:
            print(f"  ✗ {doc.as_posix()}  ->  {target}", file=sys.stderr)
        print(
            "\n文件被移动或改名时，引用不会自动跟着改 —— 请逐条修正。",
            file=sys.stderr,
        )
        return 1

    print(f"  ✓ 文档链接（{len(docs)} 份文档，{checked} 条相对链接）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
