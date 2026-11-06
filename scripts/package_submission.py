# -*- coding: utf-8 -*-
"""把参赛需要提交的附件整理到一个新目录，并打成 zip。

内容：参赛文档、演示视频、Android 安装包、全部源码、补充示意图。
排除：依赖与构建产物（.venv、node_modules、build、.dart_tool、.gradle…）、
      缓存、日志、本机配置（local.properties）、临时脚本。
"""

import os
import shutil
import zipfile
from pathlib import Path

ROOT = Path(r"D:\Code\VitalTeen")
PKG_NAME = "提交材料_健知行绎"
PKG = ROOT / PKG_NAME
ZIP = ROOT / "健知行绎_参赛提交材料_20261022.zip"

DOCX = ROOT / "人工智能工具使用情况说明（补充完成）.docx"
VIDEO = ROOT / "实机测试.mp4"
APK = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
FIGS = ROOT / "ai-figures"
FIG_SCRIPT = ROOT / "scripts" / "make_ai_figures.py"

# 目录名黑名单（任意层级）
SKIP_DIRS = {
    ".git", ".venv", "node_modules", "build", ".dart_tool", ".gradle", ".kotlin",
    ".idea", ".ruff_cache", ".pytest_cache", "__pycache__", ".dsh-acl-report",
    ".preview-center", "ai-usage", ".vscode", "dist_package",
}
# 文件名/后缀黑名单
SKIP_FILES = {".flutter-plugins-dependencies", "local.properties", "Thumbs.db",
              ".DS_Store", ".npmrc",
              # 文档加工用的临时脚本，不属于作品源码
              "fill_ai_docx.py", "fix_footer_pagenum.py", "fix_footer_center.py",
              "package_submission.py"}
SKIP_SUFFIX = (".iml", ".log", ".tmp")
SKIP_PREFIX = ("tmp_",)


def ignored(name: str, is_dir: bool) -> bool:
    if is_dir:
        return name in SKIP_DIRS or name.startswith(".preview-")
    return (name in SKIP_FILES or name.endswith(SKIP_SUFFIX)
            or name.startswith(SKIP_PREFIX))


def _on_rm_error(func, path, exc):
    """只读文件先去掉只读属性再删。"""
    os.chmod(path, 0o666)
    func(path)


def force_rmtree(path: Path):
    if path.exists():
        shutil.rmtree(path, onexc=_on_rm_error)


def copy(src: Path, dst: Path):
    """复制并去掉源文件的只读属性（原始素材多为只读）。"""
    shutil.copy2(src, dst)
    os.chmod(dst, 0o666)


def copy_tree(src: Path, dst: Path) -> tuple[int, int]:
    """按规则复制目录，返回（文件数, 字节数）。"""
    n = size = 0
    for base, dirs, files in os.walk(src):
        dirs[:] = [d for d in dirs if not ignored(d, True)]
        rel = Path(base).relative_to(src)
        target = dst / rel
        target.mkdir(parents=True, exist_ok=True)
        for f in files:
            if ignored(f, False):
                continue
            s = Path(base) / f
            copy(s, target / f)
            n += 1
            size += s.stat().st_size
    return n, size


MANIFEST = """健知行绎 —— 参赛提交材料清单
=====================================

作品名称：健知行绎：基于 Laya 轻量决策模型的青少年体态视觉鉴评与导引平台
作品编号：319378
参赛赛道：本科及以上学历赛道（数据可视化与智能交互）

目录结构
--------
00_材料清单.txt            本文件
01_参赛文档/               人工智能工具使用情况说明（Word）
02_演示视频/               实机演示录屏（MP4）
03_安装包/                 Android 安装包与安装说明
04_源代码/                 全部工程源码与设计文档
05_补充材料/               说明文档中三幅示意图的源文件与生成脚本

01_参赛文档
-----------
人工智能工具使用情况说明.docx
  按赛事模板填写，含 AI 工具清单、三个代表性使用环节、学生原创贡献、
  过程材料示意图、合规说明。图中三幅示意图均为团队自绘。

02_演示视频
-----------
健知行绎_实机演示.mp4
  手机实机录屏，演示动作采集、姿态判定、报告与体态知识库。视频画面为
  软件真实运行录屏，未使用合成或渲染动画。

03_安装包
---------
健知行绎_Android_通用版.apk
  Flutter 构建的 release 包，含 arm64-v8a / armeabi-v7a / x86_64 三种 ABI，
  可直接安装于 Android 8.0 及以上设备。安装时需允许「未知来源应用」。
  详见同目录「安装说明.txt」。

04_源代码
---------
沿用仓库结构，未包含任何第三方依赖与构建产物，可直接对照阅读：

  README.md              仓库总览、当前进度、三条工程约定、启动方式
  requirements-dev.txt   Python 侧开发依赖
  domain/                领域层 Python 参考实现：几何算子、特征、状态机、规则引擎
  server/                决策服务（Flask + Laya 客户端、方案库、文案模板）
  ml/                    数据集管线、微调与校准评测
  shared/                跨语言共享资产：golden fixtures、契约 schema、阈值表
  app/                   Flutter 手机端（含与 Python 参考实现逐值对齐的测试）
  web/                   Vue3 数据大屏（含 dist 构建产物，可离线打开）
  docs/                  设计文档：领域层规格、端侧移植指南、环境搭建、品牌资产
  scripts/               仓库自检脚本（check_all / check_docs / sync_assets）

未包含：.git 历史、虚拟环境、node_modules、Flutter 构建中间产物。

05_补充材料
-----------
示意图/fig1-human-ai-division.png    AI 参与环节与人工接管节点
示意图/fig2-model-boundary.png       端侧计算与服务端决策的数据链路
示意图/fig3-admission-gates.png      AI 输出的四道准入门槛
示意图/make_ai_figures.py            上述三图的生成脚本（Pillow 绘制）

运行与验证（如需复核）
----------------------
  domain/   PYTHONPATH=src python -m pytest tests/ -q
  server/   python -m pytest tests/ -q
  web/      npm install && npm run test && npm run build
  app/      flutter test && flutter analyze

说明
----
- 本说明中的截图与视频均已完成脱敏，不含真实用户人脸、姓名与账号信息。
- 源代码中不包含任何密钥；服务端密钥通过环境变量注入。
- 第三方资源（模型、字体、地图数据等）的名称、来源与授权情况见
  《第三方资源说明》，与本包一并提交。
"""


def main():
    force_rmtree(PKG)
    PKG.mkdir(parents=True)

    report = []

    # 00 清单
    (PKG / "00_材料清单.txt").write_text(MANIFEST, encoding="utf-8-sig")
    report.append(("00_材料清单.txt", 1, (PKG / "00_材料清单.txt").stat().st_size))

    # 01 文档
    d1 = PKG / "01_参赛文档"
    d1.mkdir()
    copy(DOCX, d1 / "人工智能工具使用情况说明.docx")
    report.append(("01_参赛文档", 1, (d1 / "人工智能工具使用情况说明.docx").stat().st_size))

    # 02 视频
    d2 = PKG / "02_演示视频"
    d2.mkdir()
    copy(VIDEO, d2 / "健知行绎_实机演示.mp4")
    report.append(("02_演示视频", 1, (d2 / "健知行绎_实机演示.mp4").stat().st_size))

    # 03 安装包
    d3 = PKG / "03_安装包"
    d3.mkdir()
    copy(APK, d3 / "健知行绎_Android_通用版.apk")
    (d3 / "安装说明.txt").write_text(
        "健知行绎 Android 安装说明\n"
        "=============================\n\n"
        "文件：健知行绎_Android_通用版.apk\n"
        "适用系统：Android 8.0（API 26）及以上\n"
        "包含架构：arm64-v8a、armeabi-v7a、x86_64（通用包，无需挑选）\n\n"
        "安装步骤\n"
        "1. 把 apk 传到手机上（数据线、文件传输或网盘均可）。\n"
        "2. 在文件管理器中点击该 apk。\n"
        "3. 系统提示「未知来源应用」时，允许本次安装。\n"
        "4. 安装完成后打开，首次进入需授予相机权限（用于动作采集）。\n\n"
        "说明\n"
        "- 本应用为端侧推理，视频帧不上传，只在设备内计算姿态特征。\n"
        "- 练习记录仅保存在本机，不联网同步。\n"
        "- 断网状态下可正常完成动作判定与报告生成。\n",
        encoding="utf-8-sig",
    )
    apk_size = (d3 / "健知行绎_Android_通用版.apk").stat().st_size
    report.append(("03_安装包", 2, apk_size + (d3 / "安装说明.txt").stat().st_size))

    # 04 源代码
    d4 = PKG / "04_源代码"
    d4.mkdir(parents=True, exist_ok=True)
    n = size = 0
    for item in ("README.md", "requirements-dev.txt", ".gitignore", ".gitattributes"):
        p = ROOT / item
        if p.exists():
            copy(p, d4 / item)
            n += 1
            size += p.stat().st_size
    for item in ("domain", "server", "ml", "shared", "app", "web", "docs", "scripts"):
        src = ROOT / item
        if not src.exists():
            continue
        cn, cs = copy_tree(src, d4 / item)
        n += cn
        size += cs
    report.append(("04_源代码", n, size))

    # 05 补充材料
    d5 = PKG / "05_补充材料" / "示意图"
    d5.mkdir(parents=True)
    n = size = 0
    for f in sorted(FIGS.glob("*.png")):
        copy(f, d5 / f.name)
        n += 1
        size += f.stat().st_size
    if FIG_SCRIPT.exists():
        copy(FIG_SCRIPT, d5 / FIG_SCRIPT.name)
        n += 1
        size += FIG_SCRIPT.stat().st_size
    report.append(("05_补充材料", n, size))

    # 打包
    if ZIP.exists():
        ZIP.unlink()
    count = 0
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for base, dirs, files in os.walk(PKG):
            dirs.sort()
            for f in sorted(files):
                p = Path(base) / f
                zf.write(p, Path(PKG_NAME) / p.relative_to(PKG))
                count += 1

    # 校验
    with zipfile.ZipFile(ZIP) as zf:
        bad = zf.testzip()
        entries = zf.namelist()
        total_raw = sum(i.file_size for i in zf.infolist())

    print(f"{'部分':<16}{'文件数':>8}{'原始大小':>14}")
    for name, cnt, sz in report:
        print(f"{name:<16}{cnt:>8}{sz/1048576:>12.2f} MB")
    print("-" * 40)
    print(f"包内文件总数：{count}，解压后 {total_raw/1048576:.1f} MB")
    print(f"zip 大小：{ZIP.stat().st_size/1048576:.1f} MB")
    print(f"完整性校验：{'通过' if bad is None else '损坏 ' + bad}")
    print(f"条目数：{len(entries)}")
    print(f"输出：{ZIP}")


if __name__ == "__main__":
    main()
