#!/usr/bin/env python3
"""把 `shared/` 下的共享资产同步到 `app/assets/`。

    python scripts/sync_assets.py            # 同步
    python scripts/sync_assets.py --check    # 只校验是否同步（CI 与提交前用）

**为什么需要这一步**

`shared/` 里的东西（阈值表、方案库、文案模板）是端侧与服务端**必须共用**的，
而 Flutter 的 assets 必须在包目录内（`app/assets/...`），没法直接引用仓库另一处。

于是一旦两个副本漂移，端上判定就会与服务端不一致 —— **而那种不一致不会报错**，
只会让同一个动作在手机上和服务端得出不同的结论。这正是本项目一路在防的
「静默不一致」，所以同步必须可校验，而不是靠人记得复制。

单向：`shared/` → `app/assets/`。**不要反向复制**，否则真源就变成 app 了。
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

#: (源目录, 目标目录)。四份都是 App **运行时真的会读**的东西：阈值表参与判定，
#: 方案库与文案模板参与报告渲染，规则参数参与**断网时的本机判定**。
#: 少同步一份，端上就会在某个具体动作上出错 —— 或者在某一种网络状态下出错。
#:
#: fixtures 与 contracts schema **不在这里** —— 那是开发期资产（测试与代码生成用），
#: 不需要打进安装包。
SYNC_DIRS: tuple[tuple[Path, Path], ...] = (
    (ROOT / "shared" / "thresholds", ROOT / "app" / "assets" / "thresholds"),
    (ROOT / "shared" / "plans", ROOT / "app" / "assets" / "plans"),
    (ROOT / "shared" / "messages", ROOT / "app" / "assets" / "messages"),
    (ROOT / "shared" / "decision", ROOT / "app" / "assets" / "decision"),
)

#: 只同步这几种后缀。**`shared/` 下的 README 是为写它的人准备的**，
#: 端侧一个字节都不会读 —— 把它们打进安装包，只是白白占体积。
#:
#: 过滤对两侧一视同仁（源目录里算什么，目标目录里就算什么），所以有人手工
#: 往 assets 里塞一个 `.json` 照样会被「目标多出」那一条抓到。README 这类
#: 掉进滤网的东西本身不参与比对，也就不可能因为它的存在与否影响同步判定。
SYNC_SUFFIXES: tuple[str, ...] = (".json",)


def relative_files(directory: Path) -> set[str]:
    if not directory.exists():
        return set()
    return {
        str(path.relative_to(directory))
        for path in directory.rglob("*")
        if path.is_file() and path.suffix in SYNC_SUFFIXES
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="同步共享资产到 App")
    parser.add_argument("--check", action="store_true", help="只校验是否同步，不写入")
    args = parser.parse_args()

    problems: list[str] = []

    for source, target in SYNC_DIRS:
        if not source.exists():
            problems.append(f"源目录不存在：{source}")
            continue

        source_files = relative_files(source)
        target_files = relative_files(target)

        missing = sorted(source_files - target_files)
        extra = sorted(target_files - source_files)
        different = sorted(
            name
            for name in source_files & target_files
            if (source / name).read_bytes() != (target / name).read_bytes()
        )

        label = f"{source.relative_to(ROOT)} → {target.relative_to(ROOT)}"

        if args.check:
            if missing:
                problems.append(f"{label}：目标缺少 {missing}")
            if different:
                problems.append(f"{label}：内容不一致 {different}")
            if extra:
                # 多出来的 `.json` 也要报：它多半是有人手工往 assets 里塞了东西，
                # 那会绕过真源，下次同步就把它覆盖掉
                problems.append(f"{label}：目标多出 {extra}（应只由本脚本产生）")
            if not (missing or different or extra):
                print(f"  ✓ {label} 已同步（{len(source_files)} 个文件）")
            continue

        target.mkdir(parents=True, exist_ok=True)
        for name in extra:
            (target / name).unlink()
        # 只删 SYNC_SUFFIXES 里的。目录里可能还有别的文件（比如有人放了一份
        # 说明），它们不归这个脚本管。
        for name in source_files:
            destination = target / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, destination)
        print(f"  已同步 {label}（{len(source_files)} 个文件）")

    if args.check and problems:
        print("\n同步校验失败：", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        print("\n请运行 `python scripts/sync_assets.py` 修复。", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
