# -*- coding: utf-8 -*-
"""修复页脚页码换行：文本框改为不自动换行并加宽。

原因：页脚页码放在一个 WPS 浮动文本框里（固定宽 961390 EMU ≈ 2.66 cm），
文档补到二十几页后「第 24 页 共 24 页」超出宽度，文本框内自动折成两行。
"""

import os
import re
import shutil
import zipfile

TARGET = r"D:\Code\VitalTeen\人工智能工具使用情况说明（补充完成）.docx"
TMP = TARGET + ".new"

OLD_EXTENT = 'cx="961390" cy="145415"'
NEW_EXTENT = 'cx="3200000" cy="145415"'   # 约 8.9 cm，远大于实际文字宽度

OLD_BODYPR = 'anchor="t"><a:spAutoFit/>'
NEW_BODYPR = 'anchor="t" wrap="none"><a:spAutoFit/>'

OLD_VML = "width:75.7pt"
NEW_VML = "width:234pt"


def fix_xml(xml: str) -> tuple[str, list[str]]:
    changes = []
    if OLD_EXTENT in xml:
        xml = xml.replace(OLD_EXTENT, NEW_EXTENT)
        changes.append("extent")
    if OLD_BODYPR in xml:
        xml = xml.replace(OLD_BODYPR, NEW_BODYPR)
        changes.append("wrap=none")
    if OLD_VML in xml:
        xml = xml.replace(OLD_VML, NEW_VML)
        changes.append("vml-width")
    return xml, changes


def main():
    with zipfile.ZipFile(TARGET) as zin:
        names = zin.namelist()
        items = {n: zin.read(n) for n in names}

    touched = {}
    for n in names:
        if re.match(r"word/(footer|header)\d*\.xml$", n):
            xml = items[n].decode("utf-8")
            if "txbxContent" not in xml:
                continue
            new_xml, changes = fix_xml(xml)
            if changes:
                items[n] = new_xml.encode("utf-8")
                touched[n] = changes

    if not touched:
        raise SystemExit("未找到需要修改的页脚")

    with zipfile.ZipFile(TMP, "w", compression=zipfile.ZIP_DEFLATED) as zout:
        for n in names:  # 每个成员只写一次，顺序不变
            zout.writestr(n, items[n])
    os.replace(TMP, TARGET)
    for k, v in touched.items():
        print("fixed", k, v)


if __name__ == "__main__":
    main()
