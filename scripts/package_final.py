# -*- coding: utf-8 -*-
"""按赛事《材料提交规范》第十节的目录结构打包参赛材料。

作品名称_作品编号/
├─01_作品及成果文件    ├─02_作品展示视频  ├─03_作品介绍文档
├─04_运行或使用说明    ├─05_补充成果材料  ├─06_第三方资源说明
└─07_AI工具使用补充说明
"""

import os
import shutil
import zipfile
from pathlib import Path

ROOT = Path(r"D:\Code\VitalTeen")
NAME = "健知行绎_319378"
PKG = ROOT / NAME
ZIP = ROOT / f"{NAME}.zip"

MAT = ROOT / "materials"
OUT = MAT / "out"
APK = ROOT / "app" / "build" / "app" / "outputs" / "flutter-apk" / "app-release.apk"
VIDEO = Path(r"D:\Code\VitalTeen-promo\out\promo.mp4")

SKIP_DIRS = {".git", ".venv", "node_modules", "build", ".dart_tool", ".gradle", ".kotlin",
             ".idea", ".ruff_cache", ".pytest_cache", "__pycache__", ".dsh-acl-report",
             "ai-usage", ".vscode"}
SKIP_FILES = {".flutter-plugins-dependencies", "local.properties", "Thumbs.db", ".DS_Store",
              ".npmrc", "fill_ai_docx.py", "fix_footer_pagenum.py", "fix_footer_center.py",
              "package_submission.py", "package_final.py"}
SKIP_SUFFIX = (".iml", ".log", ".tmp")
SKIP_PREFIX = ("tmp_",)

INDEX = """健知行绎 —— 参赛材料索引
================================

作品名称：健知行绎
作品副题：基于 Laya 轻量决策模型的青少年体态视觉鉴评与导引平台
作品编号：319378
参赛赛道：本科及以上学历赛道（数据可视化与智能交互）

压缩包目录（按《参赛作品材料提交规范》第十节整理）
--------------------------------------------------
01_作品及成果文件/     必含。安装包、全部源代码、作品截图
02_作品展示视频/       作品实际运行效果展示（1080P，63 秒）
03_作品介绍文档/       定位、创新、技术实现、成果状态、团队分工
04_运行或使用说明/     安装步骤、功能操作、5 分钟核验路径、常见问题
05_补充成果材料/       测试记录、功能清单、设计过程、应用案例
06_第三方资源说明/     开源依赖、模型与数据、素材与服务的来源与许可
07_AI工具使用补充说明/ AI 工具、使用环节、人工处理与学生原创贡献

阅读建议
--------
时间有限时：先看 02 的视频 → 01 中的作品截图 → 03 的介绍文档。
需要核验时：按 04 第六节的 5 分钟路径在手机上走一遍；按 05 第一节的命令复现测试。

说明
----
1. 本包按匿名化要求整理，不含参赛学校、团队名称、参赛学生与指导教师信息；
   文档中以「成员A—成员E」指代团队成员。
2. 文字类材料均为 PDF；可运行成果保留 APK 与源代码原格式。
3. 作品截图与展示视频均为真机运行画面，未使用概念图或渲染动画替代成果。
4. 第三方资源与 AI 使用情况分别见 06、07 两项，均属实披露。
"""

DELIVERY = """01_作品及成果文件 · 交付说明
================================

健知行绎_Android_通用版.apk
  作品主体。Flutter release 包，含 arm64-v8a、armeabi-v7a、x86_64 三种架构，
  适用于 Android 8.0 及以上设备。安装时需允许「未知来源应用」，首次进入需授予相机权限。
  安装与操作步骤见 04_运行或使用说明。

源代码/
  完整工程源码与设计文档，未包含第三方依赖与构建产物：
    domain/   领域层 Python 参考实现（特征、状态机、规则、阈值治理）
    server/   决策服务（Flask + Laya 客户端、方案库、文案模板）
    ml/       数据集管线、微调与校准评测
    shared/   golden fixtures、契约 schema、阈值表
    app/      Flutter 手机端（含与 Python 参考实现逐值对齐的测试）
    web/      Vue 3 数据大屏（含 dist 构建产物，可离线打开）
    docs/     设计文档
    scripts/  仓库自检脚本

作品截图/
  真机运行画面，用于快速了解界面与成果形态；对应说明见 03、04 两项材料。

说明
----
- 视频帧不出设备，上行只有结构化特征与质量指标（仅联网决策时发生）。
- 本机记录不联网同步；卸载应用会一并删除。
- 作品截图已裁剪系统状态栏。
"""


def ignored(name, is_dir):
    if is_dir:
        return name in SKIP_DIRS or name.startswith(".preview-")
    return (name in SKIP_FILES or name.endswith(SKIP_SUFFIX)
            or name.startswith(SKIP_PREFIX))


def _on_rm_error(func, path, exc):
    os.chmod(path, 0o666)
    func(path)


def force_rmtree(path):
    if path.exists():
        shutil.rmtree(path, onexc=_on_rm_error)


def copy(src, dst):
    shutil.copy2(src, dst)
    os.chmod(dst, 0o666)


def copy_tree(src, dst):
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


def main():
    force_rmtree(PKG)
    PKG.mkdir(parents=True)
    report = []

    (PKG / "00_材料索引.txt").write_text(INDEX, encoding="utf-8-sig")
    report.append(("00_材料索引", 1, (PKG / "00_材料索引.txt").stat().st_size))

    # 01 作品及成果文件
    d1 = PKG / "01_作品及成果文件"
    (d1 / "作品截图").mkdir(parents=True)
    (d1 / "源代码").mkdir()
    copy(APK, d1 / "健知行绎_Android_通用版.apk")
    (d1 / "交付说明.txt").write_text(DELIVERY, encoding="utf-8-sig")

    shots = [("s1_welcome.png", "01_启动界面.png"),
             ("s2_practice.png", "02_练习页_实时骨架与计数.png"),
             ("s3_report.png", "03_组末报告.png"),
             ("s4_posture.png", "04_体态倾向与处方.png")]
    for src, dst in shots:
        copy(MAT / "screens" / src, d1 / "作品截图" / dst)

    n = size = 0
    for item in ("README.md", "requirements-dev.txt", ".gitignore", ".gitattributes"):
        p = ROOT / item
        if p.exists():
            copy(p, d1 / "源代码" / item)
            n += 1
            size += p.stat().st_size
    for item in ("domain", "server", "ml", "shared", "app", "web", "docs", "scripts"):
        if (ROOT / item).exists():
            cn, cs = copy_tree(ROOT / item, d1 / "源代码" / item)
            n += cn
            size += cs
    apk_size = (d1 / "健知行绎_Android_通用版.apk").stat().st_size
    shot_size = sum((d1 / "作品截图" / d).stat().st_size for _, d in shots)
    report.append(("01_作品及成果文件", 4 + len(shots) + n,
                   apk_size + shot_size + size + (d1 / "交付说明.txt").stat().st_size))

    # 02 视频
    d2 = PKG / "02_作品展示视频"
    d2.mkdir()
    copy(VIDEO, d2 / "健知行绎_作品展示视频.mp4")
    report.append(("02_作品展示视频", 1, (d2 / "健知行绎_作品展示视频.mp4").stat().st_size))

    # 03-07 文档
    docs = [
        ("03_作品介绍文档", "健知行绎_作品介绍文档.pdf"),
        ("04_运行或使用说明", "健知行绎_运行或使用说明.pdf"),
        ("05_补充成果材料", "健知行绎_补充成果材料.pdf"),
        ("06_第三方资源说明", "健知行绎_第三方资源说明.pdf"),
    ]
    for folder, fname in docs:
        d = PKG / folder
        d.mkdir()
        copy(OUT / fname, d / fname)
        report.append((folder, 1, (d / fname).stat().st_size))

    d7 = PKG / "07_AI工具使用补充说明"
    d7.mkdir()
    for f in ("健知行绎_人工智能工具使用情况说明.pdf",):
        copy(OUT / f, d7 / f)
    copy(ROOT / "人工智能工具使用情况说明（补充完成）.docx",
         d7 / "健知行绎_人工智能工具使用情况说明.docx")
    report.append(("07_AI工具使用补充说明", 2,
                   sum(f.stat().st_size for f in d7.iterdir())))

    # 打包
    if ZIP.exists():
        ZIP.unlink()
    count = 0
    with zipfile.ZipFile(ZIP, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as zf:
        for base, dirs, files in os.walk(PKG):
            dirs.sort()
            for f in sorted(files):
                p = Path(base) / f
                zf.write(p, Path(NAME) / p.relative_to(PKG))
                count += 1

    with zipfile.ZipFile(ZIP) as zf:
        bad = zf.testzip()
        raw = sum(i.file_size for i in zf.infolist())
        entries = len(zf.namelist())

    print(f"{'部分':<22}{'文件数':>7}{'大小':>12}")
    for name, cnt, sz in report:
        print(f"{name:<22}{cnt:>7}{sz/1048576:>10.2f} MB")
    print("-" * 44)
    print(f"条目 {entries} | 解压后 {raw/1048576:.1f} MB | zip {ZIP.stat().st_size/1048576:.1f} MB")
    print("完整性:", "通过" if bad is None else f"损坏 {bad}")
    print("输出:", ZIP)


if __name__ == "__main__":
    main()
