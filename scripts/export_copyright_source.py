# -*- coding: utf-8 -*-
"""导出软著申报用的源代码包与源程序文档。

软著对源程序的要求是：**前 30 页 + 后 30 页，共 60 页，每页不少于 50 行**，
页眉写软件全称与版本号。这个脚本做三件事：

1. 把 App 端源码整理成一份干净的目录并打成 zip（不含 web/、测试、依赖与构建产物）；
2. 生成 60 页的 `源程序.docx`（每页 50 行，页眉写名称与版本，页脚写页码）；
3. 写一份 `代码清单.txt`（文件、行数、以及哪些页被省略）。

用法：
    python scripts/export_copyright_source.py
    python scripts/export_copyright_source.py --name "某某软件" --version V1.0

生成之后用 LibreOffice 转 PDF（见 `docs/soft-copyright.md`）。
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import zipfile
from pathlib import Path

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_TAB_ALIGNMENT
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"

DEFAULT_NAME = "健知行绎青少年体态智能导引软件"
DEFAULT_VERSION = "V1.0"

# 源程序的阅读顺序：入口 → 设计系统 → 界面 → 会话与呈现 → 平台适配 → 领域层
# → 原生壳 → 构建配置。前 30 页从 main.dart 开始，后 30 页落在领域层与配置上。
UI_FIRST = ["design.dart", "app_icons.dart", "theme.dart"]

# 只收文本源码与随包配置；图片与二进制不是「源程序」。
TEXT_SUFFIX = {".dart", ".kt", ".xml", ".yaml", ".yml", ".gradle", ".kts", ".properties", ".json", ".md", ".txt"}
SKIP_SUFFIX = {".webp", ".png", ".jpg", ".jpeg", ".ttf", ".otf", ".jar", ".apk", ".bak"}

# zip 里不放的东西：测试与构建产物、本机配置、调试入口之外的一次性脚本。
ZIP_SKIP_DIRS = {"build", ".dart_tool", ".gradle", ".idea", ".kotlin", "test", "tool"}
ZIP_SKIP_FILES = {".flutter-plugins-dependencies", "local.properties", "gradlew", "gradlew.bat"}


def _dart_files(sub: str) -> list[Path]:
    base = APP / "lib" / sub
    if not base.exists():
        return []
    return sorted(p for p in base.rglob("*.dart") if not p.name.endswith(".bak"))


def source_files() -> list[Path]:
    """按阅读顺序列出随包提交的全部源码与配置（zip 用）。"""
    files: list[Path] = [APP / "lib" / "main.dart"]

    ui = _dart_files("ui")
    ordered = [APP / "lib" / "ui" / name for name in UI_FIRST]
    files += [p for p in ordered if p.exists()]
    files += [p for p in ui if p.name not in UI_FIRST]

    files += _dart_files("app")
    files += _dart_files("platform")
    files += _dart_files("domain")
    files.append(APP / "lib" / "phase0" / "fps_probe.dart")

    files += [
        APP / "android/app/src/main/kotlin/cn/vitalteen/vitalteen_app/MainActivity.kt",
        APP / "android/app/src/main/AndroidManifest.xml",
        APP / "android/app/src/main/res/values/styles.xml",
        APP / "android/app/src/main/res/xml/network_security_config.xml",
        APP / "android/app/src/main/res/drawable/launch_background.xml",
        APP / "android/app/build.gradle.kts",
        APP / "android/build.gradle.kts",
        APP / "android/settings.gradle.kts",
        APP / "android/gradle.properties",
        APP / "android/gradle/wrapper/gradle-wrapper.properties",
        APP / "pubspec.yaml",
        APP / "analysis_options.yaml",
    ]
    return [p for p in files if p.exists()]


def listing_files() -> list[Path]:
    """源程序文档只取「程序代码」：Dart 与 Kotlin。

    构建脚本、清单与资源 XML 属于工程配置，不是程序的源代码 —— 它们在 zip 里
    完整提交，但不进 60 页源程序文档。这样也避开了那份 AndroidManifest 里
    一条 160 多列的长属性：它会把整份文档的可用字号拖到 6pt 以下。
    """
    return [
        p
        for p in source_files()
        if p.suffix == ".dart"
        or p.name == "MainActivity.kt"
    ]


def read_lines(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    # 去掉文件末尾那一个空串：它不是代码行。
    if lines and lines[-1] == "":
        lines.pop()
    return [line.replace("\t", "    ").rstrip() for line in lines]


def display_width(line: str) -> int:
    """中文按两列算 —— 等宽字体里一个汉字正好占两个西文字符的位置。"""
    return sum(2 if ord(ch) > 0x2E80 else 1 for ch in line)


def zip_source(out_dir: Path, name: str, version: str, files: list[Path]) -> tuple[Path, int]:
    """把源码复制成干净目录并打包。返回 (zip 路径, 文件数)。"""
    stage = out_dir / f"{name}_{version}_源代码"
    if stage.exists():
        shutil.rmtree(stage)
    stage.mkdir(parents=True)

    copied = 0
    for src in files:
        rel = src.relative_to(APP)
        if any(part in ZIP_SKIP_DIRS for part in rel.parts):
            continue
        if src.name in ZIP_SKIP_FILES or src.suffix.lower() in SKIP_SUFFIX:
            continue
        dst = stage / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1

    # 随包资源（阈值表、文案、方案库、断网判定常量）。它们是运行所需的数据，
    # 不是代码，但缺了软件就跑不出正确结论，所以放在 assets/ 里一并提交。
    for src in sorted((APP / "assets").rglob("*.json")):
        rel = src.relative_to(APP)
        dst = stage / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
        copied += 1

    readme = APP / "README.md"
    if readme.exists():
        shutil.copy2(readme, stage / "README.md")

    manifest = out_dir / "代码清单.txt"
    # 带 BOM：这份清单会被拷给评审的人在 Windows 上用记事本打开，
    # 没有 BOM 的 UTF-8 在旧版记事本里会是一屏乱码。
    manifest.write_text(_manifest(name, version, files), encoding="utf-8-sig")
    shutil.copy2(manifest, stage / "代码清单.txt")

    zip_path = out_dir / f"{name}_{version}_源代码.zip"
    if zip_path.exists():
        zip_path.unlink()
    entries = [p for p in sorted(stage.rglob("*")) if p.is_file()]
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in entries:
            zf.write(path, path.relative_to(stage.parent))
    shutil.rmtree(stage)
    return zip_path, len(entries)


def _manifest(name: str, version: str, files: list[Path]) -> str:
    rows = []
    total = 0
    for path in files:
        line_count = len(read_lines(path))
        total += line_count
        rows.append((path.relative_to(APP).as_posix(), line_count))

    width = max(len(r[0]) for r in rows)
    body = "\n".join(f"{path.ljust(width)}  {count:6d}" for path, count in rows)

    assets = sorted((APP / "assets").rglob("*.json"))
    asset_rows = "\n".join(
        f"{p.relative_to(APP).as_posix().ljust(width)}  {p.stat().st_size:6d} B"
        for p in assets
    )
    return f"""软件名称：{name}
版本号：{version}

源程序文件与行数（不含第三方依赖与构建产物）
============================================
{body}
{"-" * (width + 8)}
合计 {len(rows)} 个文件，{total} 行

随包资源（运行所需的数据，不计入源程序行数）
============================================
{asset_rows}

说明
----
1. 本清单对应压缩包内的 lib/、android/、assets/、pubspec.yaml 等路径。
2. 已排除：web/（Vue 数据大屏）、test/（测试代码）、build/、.dart_tool/、
   .gradle/、第三方依赖与本机配置（local.properties）。
3. 图片与字体等二进制素材未列入源程序；assets/ 下四份 JSON 是运行所需的
   阈值、文案、方案与断网判定常量，随包提交。
4. 源程序文档（60 页）的取法：按上面这个顺序排成一份长清单，取前 1500 行
   与最后 1500 行；文档不排空行，每页 50 行。
"""


def _set_run_font(run, ascii_font: str, east_asia: str, size: float) -> None:
    run.font.name = ascii_font
    run.font.size = Pt(size)
    rpr = run._element.get_or_add_rPr()
    fonts = rpr.find(qn("w:rFonts"))
    if fonts is None:
        fonts = OxmlElement("w:rFonts")
        rpr.append(fonts)
    fonts.set(qn("w:ascii"), ascii_font)
    fonts.set(qn("w:hAnsi"), ascii_font)
    fonts.set(qn("w:eastAsia"), east_asia)


def _add_field(paragraph, instr: str) -> None:
    """插入一个 Word 域（PAGE / NUMPAGES），LibreOffice 转 PDF 时会求值。

    四个 fldChar 分成四个 run 写：塞进同一个 run 在 Word 里能认，在部分
    转换器里不求值，页脚会原样显示成「第 1 页 共 1 页」。
    """
    run_begin = paragraph.add_run()
    fld_begin = OxmlElement("w:fldChar")
    fld_begin.set(qn("w:fldCharType"), "begin")
    run_begin._r.append(fld_begin)

    run_instr = paragraph.add_run()
    instr_el = OxmlElement("w:instrText")
    instr_el.set(qn("xml:space"), "preserve")
    instr_el.text = f" {instr} "
    run_instr._r.append(instr_el)

    run_sep = paragraph.add_run()
    fld_sep = OxmlElement("w:fldChar")
    fld_sep.set(qn("w:fldCharType"), "separate")
    run_sep._r.append(fld_sep)

    run_text = paragraph.add_run("1")

    run_end = paragraph.add_run()
    fld_end = OxmlElement("w:fldChar")
    fld_end.set(qn("w:fldCharType"), "end")
    run_end._r.append(fld_end)


def build_docx(
    path: Path,
    name: str,
    version: str,
    lines: list[str],
    per_page: int,
    font_size: float,
) -> None:
    doc = Document()
    section = doc.sections[0]
    section.page_width = Cm(21.0)
    section.page_height = Cm(29.7)
    section.top_margin = Cm(2.0)
    section.bottom_margin = Cm(1.8)
    section.left_margin = Cm(1.15)
    section.right_margin = Cm(1.15)
    section.header_distance = Cm(1.0)
    section.footer_distance = Cm(0.9)

    # 页眉：左边软件全称与版本，右边「源程序」。
    header = section.header
    header_para = header.paragraphs[0]
    header_para.paragraph_format.tab_stops.add_tab_stop(
        Cm(21.0 - 1.15 - 1.15), WD_TAB_ALIGNMENT.RIGHT
    )
    header_para.paragraph_format.space_after = Pt(0)
    left = header_para.add_run(f"{name} {version}")
    _set_run_font(left, "宋体", "宋体", 9)
    middle = header_para.add_run("\t")
    _set_run_font(middle, "宋体", "宋体", 9)
    right = header_para.add_run("源程序")
    _set_run_font(right, "宋体", "宋体", 9)

    # 页脚：第 X 页 共 60 页
    footer = section.footer
    footer_para = footer.paragraphs[0]
    footer_para.alignment = WD_ALIGN_PARAGRAPH.CENTER
    footer_para.paragraph_format.space_after = Pt(0)
    for text in ("第 ",):
        _set_run_font(footer_para.add_run(text), "宋体", "宋体", 9)
    _add_field(footer_para, "PAGE")
    _set_run_font(footer_para.add_run(" 页 共 "), "宋体", "宋体", 9)
    _add_field(footer_para, "NUMPAGES")
    _set_run_font(footer_para.add_run(" 页"), "宋体", "宋体", 9)

    style = doc.styles["Normal"]
    style.paragraph_format.space_before = Pt(0)
    style.paragraph_format.space_after = Pt(0)
    style.paragraph_format.line_spacing = Pt(12)

    for index, line in enumerate(lines):
        para = doc.add_paragraph()
        fmt = para.paragraph_format
        fmt.space_before = Pt(0)
        fmt.space_after = Pt(0)
        fmt.line_spacing = Pt(12)
        fmt.widow_control = False
        if index and index % per_page == 0:
            fmt.page_break_before = True
        run = para.add_run(line if line else " ")
        _set_run_font(run, "Consolas", "宋体", font_size)

    doc.save(path)


def pick_font_size(lines: list[str], usable_cm: float) -> tuple[float, int]:
    """选一个能让最长的一行也不折行的字号（7 ~ 9pt）。"""
    widest = max(display_width(line) for line in lines)
    usable_pt = usable_cm / 2.54 * 72
    for size in [9.0, 8.75, 8.5, 8.25, 8.0, 7.75, 7.5, 7.25, 7.0]:
        if widest * size * 0.5498 <= usable_pt:
            return size, widest
    return 7.0, widest

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default=DEFAULT_NAME)
    parser.add_argument("--version", default=DEFAULT_VERSION)
    parser.add_argument("--out", default=None)
    parser.add_argument("--per-page", type=int, default=50)
    parser.add_argument("--front", type=int, default=30)
    parser.add_argument("--back", type=int, default=30)
    args = parser.parse_args()

    out_dir = Path(args.out) if args.out else ROOT / "软著申报" / f"{args.name}_{args.version}"
    out_dir.mkdir(parents=True, exist_ok=True)

    files = source_files()
    listing = listing_files()
    # **源程序文档不排空行。** 软著要求每页不少于 50 行，而空行会被审阅的人
    # 当成「这一页没写满」；去掉空行之后，每一页正好 50 行实打实的代码。
    all_lines: list[str] = []
    for path in listing:
        all_lines.extend(line for line in read_lines(path) if line.strip())

    per_page = args.per_page
    front_lines = args.front * per_page
    back_lines = args.back * per_page
    submitted = all_lines[:front_lines] + all_lines[-back_lines:]
    font_size, widest = pick_font_size(submitted, 21.0 - 2.30)
    if widest * font_size * 0.5498 > (21.0 - 2.30) / 2.54 * 72:
        raise SystemExit(
            f"最长一行 {widest} 列，7pt 下仍会折行；请把这一行拆短或换更窄的等宽字体。"
        )

    docx_path = out_dir / f"{args.name}_{args.version}_源程序.docx"
    build_docx(docx_path, args.name, args.version, submitted, per_page, font_size)

    zip_path, copied = zip_source(out_dir, args.name, args.version, files)
    total_pages = (len(all_lines) + per_page - 1) // per_page

    print(f"随包源码：{len(files)} 个文件（含 Android 配置与资源清单）")
    print(f"源程序文档：{len(listing)} 个文件 / {len(all_lines)} 行 / 约 {total_pages} 页")
    print(f"提交页：前 {args.front} 页 + 后 {args.back} 页 = {front_lines + back_lines} 行")
    print(f"最宽一行：{widest} 列，字号 {font_size}pt（左右各 1.15cm）")
    print(f"文档：{docx_path}")
    print(f"压缩包：{zip_path}（{copied} 个文件）")
    print("下一步：用 LibreOffice 把 docx 转成 pdf。")


if __name__ == "__main__":
    main()
