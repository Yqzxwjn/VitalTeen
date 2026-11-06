#!/usr/bin/env python3
"""一条命令跑完整个仓库的检查。

    python scripts/check_all.py

各模块的测试套件，加上全部跨语言一致性自检（fixtures / schema / 方案库导出 /
资产同步 / 文档链接），一次性跑完并给出汇总。**具体项数见运行输出** ——
写死在文档里的数字只会过期。

**为什么需要它**：单条命令有十几个，分属不同目录、要设不同的 PYTHONPATH、
还要区分 Python 与 Flutter 两套环境。漏跑一条不会有任何提示 ——
而那一条恰好可能就是唯一红着的。答辩前一天最不该发生的事，就是以为全绿了。

用 Python 而不是 shell 脚本：Windows 上 Git Bash、PowerShell、cmd 对同一个脚本
的处理差别很大，而本仓库的主要开发环境是 Windows。Python 是硬依赖，用它没有
额外成本。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def find_python() -> Path:
    """优先使用项目虚拟环境里的解释器。

    直接用 ``sys.executable`` 看起来自然，但脚本若被**系统 Python** 跑起来，
    那个解释器里没有 pytest / pydantic —— 于是所有 Python 检查一起红，
    而报错只有一句「No module named pytest」，看不出真正的病因。
    """
    for candidate in (
        ROOT / ".venv" / "Scripts" / "python.exe",  # Windows
        ROOT / ".venv" / "bin" / "python",  # POSIX
    ):
        if candidate.exists():
            return candidate
    return Path(sys.executable)


def find_flutter() -> str | None:
    """定位 flutter 可执行文件，找不到返回 None。

    **不能指望它已在 PATH 上。** 本脚本可能跑在一个比 Flutter 安装更早启动的
    终端里（PATH 的改动只对新开的终端生效），而子进程继承的是那个旧环境。
    这与 Python 那边的问题是同一类：环境的可见性不该由「你什么时候开的终端」决定。
    """
    found = shutil.which("flutter")
    if found:
        return found
    for candidate in (
        Path("D:/dev/flutter/bin/flutter.bat"),
        Path("C:/dev/flutter/bin/flutter.bat"),
        Path.home() / "flutter" / "bin" / "flutter.bat",
        Path("/opt/flutter/bin/flutter"),
    ):
        if candidate.exists():
            return str(candidate)
    return None


PY = str(find_python())
FLUTTER = find_flutter()

#: 装齐这些包，Python 侧的检查才能跑
REQUIRED_MODULES = ("pytest", "pydantic", "numpy")


@dataclass(frozen=True, slots=True)
class Check:
    """一项检查。

    ``requires`` 声明它依赖哪套工具链（``"python"`` / ``"flutter"``）。
    缺哪套就只跳过它、其余照跑 —— 前端那几项与 Python 环境无关，没必要一起牺牲。
    """

    name: str
    cwd: Path
    command: list[str]
    env_extra: dict[str, str] | None = None
    requires: str | None = None


#: 从国内镜像拉 Flutter 依赖。不设的话首次 pub get 会非常慢甚至超时。
_FLUTTER_ENV = {
    "PUB_HOSTED_URL": "https://pub.flutter-io.cn",
    "FLUTTER_STORAGE_BASE_URL": "https://storage.flutter-io.cn",
}


def build_checks() -> list[Check]:
    domain = ROOT / "domain"
    server = ROOT / "server"
    ml = ROOT / "ml"
    web = ROOT / "web"
    app = ROOT / "app"

    domain_env = {"PYTHONPATH": str(domain / "src")}
    ml_env = {"PYTHONPATH": str(ml / "src")}

    return [
        Check("领域层 · 测试", domain, [PY, "-m", "pytest", "tests/", "-q"], domain_env, "python"),
        Check(
            "领域层 · fixtures 同步",
            domain,
            [PY, "-m", "tools.build_fixtures", "--check"],
            domain_env,
            "python",
        ),
        Check("决策服务 · 测试", server, [PY, "-m", "pytest", "tests/", "-q"], None, "python"),
        Check(
            "决策服务 · schema 同步",
            server,
            [PY, "-m", "tools.export_schema", "--check"],
            None,
            "python",
        ),
        # 决策请求的跨语言一致性向量：Python 侧（adapter.py）生成期望值，
        # Dart 侧（decision_request.dart）必须复现。两边任一漂移都不会报错，
        # 只会让端上发出去的请求与服务端以为的字段悄悄错开，所以必须在这里拦。
        Check(
            "决策服务 · 请求 fixture 同步",
            server,
            [PY, "-m", "tools.build_request_fixture", "--check"],
            {"PYTHONPATH": f"{server}{os.pathsep}{domain / 'src'}"},
            "python",
        ),
        # 响应 fixture 是端侧**手写**响应模型唯一的东西在锁它。服务端改了必填字段
        # 而没人重新生成，端侧会一路解析到运行时才炸 —— 那时用户已经做完一组动作了。
        Check(
            "决策服务 · 响应 fixture 同步",
            server,
            [PY, "-m", "tools.build_response_fixture", "--check"],
            {"PYTHONPATH": f"{server}{os.pathsep}{domain / 'src'}"},
            "python",
        ),
        # 方案库是 Python 真源 → shared/plans/ 的导出物。不同步的表现是**用户看到的
        # 动作要领是旧的**，而没有任何东西会报错。
        Check(
            "决策服务 · 方案库导出同步",
            server,
            [PY, "-m", "tools.export_plans", "--check"],
            None,
            "python",
        ),
        # 工程参数（质量门、严重度切点、评分权重、评级阶梯）是手机端在**断网时**
        # 复现判定的依据。不同步的表现最难看：同一组动作，连不连电脑会得到两份
        # 不同的报告，而两份看起来都正常。
        Check(
            "决策服务 · 规则参数导出同步",
            server,
            [PY, "-m", "tools.export_rule_settings", "--check"],
            None,
            "python",
        ),
        # 阈值表是 shared/ → app/assets/ 的单向同步产物。漂移不会报错，
        # 只会让端上判定与服务端对同一次动作给出不同结论，所以必须在这里拦。
        Check(
            "端侧 · 资产同步",
            ROOT,
            [PY, str(ROOT / "scripts" / "sync_assets.py"), "--check"],
            None,
            "python",
        ),
        # 文档之间的相对链接：移动文件不会让任何引用报错，只会让「详见 xxx.md」
        # 指向空气，而文档照常读得通。同属「把静默失效提前到提交之前」这类检查。
        Check(
            "仓库 · 文档链接",
            ROOT,
            [PY, str(ROOT / "scripts" / "check_docs.py")],
            None,
            "python",
        ),
        Check("校准评测 · 测试", ml, [PY, "-m", "pytest", "tests/", "-q"], ml_env, "python"),
        Check("数据大屏 · 测试", web, ["npm", "run", "--silent", "test"]),
        Check("数据大屏 · 类型检查", web, ["npm", "run", "--silent", "typecheck"]),
        Check("数据大屏 · 构建", web, ["npm", "run", "--silent", "build"]),
        Check("端侧 · 静态检查", app, [FLUTTER or "flutter", "analyze"], _FLUTTER_ENV, "flutter"),
        Check("端侧 · 测试", app, [FLUTTER or "flutter", "test"], _FLUTTER_ENV, "flutter"),
    ]


def preflight_python() -> str | None:
    """确认解释器具备运行 Python 检查所需的依赖。返回错误说明，或 None 表示就绪。"""
    probe_code = f"import {', '.join(REQUIRED_MODULES)}"
    try:
        probe = subprocess.run(  # noqa: S603
            [PY, "-c", probe_code], capture_output=True, text=True, check=False
        )
    except OSError as exc:
        return f"无法执行 {PY}：{exc}"

    if probe.returncode == 0:
        return None

    missing = probe.stderr.strip().splitlines()[-1] if probe.stderr.strip() else "依赖缺失"
    venv_python = ".venv\\Scripts\\python.exe" if os.name == "nt" else ".venv/bin/python"
    return (
        f"解释器缺少 Python 测试依赖：{missing}\n"
        f"  当前解释器：{PY}\n"
        "  请先创建虚拟环境并安装依赖：\n"
        "    python -m venv .venv\n"
        f"    {venv_python} -m pip install -r requirements-dev.txt\n"
        f"  然后直接用它的解释器跑本脚本：{venv_python} scripts/check_all.py"
    )


def run(check: Check) -> tuple[bool, float, str]:
    """执行一项检查，返回 (是否通过, 耗时秒, 输出)。"""
    env = dict(os.environ)
    if check.env_extra:
        env.update(check.env_extra)

    started = time.perf_counter()
    try:
        completed = subprocess.run(  # noqa: S603
            check.command,
            cwd=check.cwd,
            env=env,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            # Windows 上 npm / flutter 都是 .cmd / .bat，不经 shell 找不到
            shell=os.name == "nt",
            check=False,
        )
    except FileNotFoundError as exc:
        return False, 0.0, f"命令不存在：{exc}"
    elapsed = time.perf_counter() - started

    output = (completed.stdout or "") + (completed.stderr or "")
    return completed.returncode == 0, elapsed, output.strip()


def tail(text: str, lines: int = 12) -> str:
    """失败时只显示末尾若干行 —— 整段输出会把汇总表冲得看不见。"""
    parts = [line for line in text.splitlines() if line.strip()]
    return "\n".join(parts[-lines:]) if parts else "（无输出）"


def main() -> int:
    checks = build_checks()
    width = max(len(check.name) for check in checks)

    print(f"仓库自检 · {ROOT}")
    print(f"Python  · {PY}")
    print(f"Flutter · {FLUTTER or '未找到'}\n")

    unavailable: dict[str, str] = {}
    if (problem := preflight_python()) is not None:
        unavailable["python"] = problem
    if FLUTTER is None:
        unavailable["flutter"] = (
            "未找到 flutter 可执行文件。\n"
            "  已查找 PATH、D:\\dev\\flutter\\bin、~/flutter/bin 等处。\n"
            "  若尚未安装，见 docs/phase0-environment.md。"
        )

    for tool, problem in unavailable.items():
        print(f"⚠ {tool} 环境未就绪，相关检查将跳过：\n{problem}\n")

    failures: list[tuple[Check, str]] = []
    skipped = 0

    for check in checks:
        if check.requires is not None and check.requires in unavailable:
            print(f"  –  {check.name.ljust(width)}  跳过")
            skipped += 1
            continue
        ok, elapsed, output = run(check)
        print(f"  {'✓' if ok else '✗'}  {check.name.ljust(width)}  {elapsed:6.2f}s")
        if not ok:
            failures.append((check, output))

    print()
    if failures:
        print(f"{len(failures)} 项失败：\n")
        for check, output in failures:
            print(f"── {check.name} " + "─" * max(0, width - len(check.name)))
            print(tail(output))
            print()
    if skipped:
        print(f"{skipped} 项跳过（工具链未就绪），跳过不等于通过。")
        return 2
    if failures:
        return 1

    print(f"全部通过（{len(checks)} 项）。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
