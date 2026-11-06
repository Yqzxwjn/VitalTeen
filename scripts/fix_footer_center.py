# -*- coding: utf-8 -*-
"""让页脚页码真正居中：文本框内的段落补 jc=center。

上一轮把文本框从 2.66cm 加宽到 8.9cm（并设为不换行）之后，
框本身仍按页边距居中，但框内那一段左对齐，文字就贴在框的左边，
看起来往左偏了约 3cm。
"""

import os
import re
import zipfile

TARGET = r"D:\Code\VitalTeen\人工智能工具使用情况说明（补充完成）.docx"
TMP = TARGET + ".new"

OLD_PPR = '<w:pPr><w:pStyle w:val="24"/></w:pPr>'
NEW_PPR = '<w:pPr><w:pStyle w:val="24"/><w:jc w:val="center"/></w:pPr>'
TEXTBOX = re.compile(r"<w:txbxContent>.*?</w:txbxContent>", re.S)


def main():
    with zipfile.ZipFile(TARGET) as zin:
        names = zin.namelist()
        items = {n: zin.read(n) for n in names}

    touched = {}
    for n in names:
        if not re.match(r"word/(footer|header)\d*\.xml$", n):
            continue
        xml = items[n].decode("utf-8")
        if "<w:txbxContent>" not in xml:
            continue

        count = [0]

        def center_block(m):
            block = m.group(0)
            if OLD_PPR in block:
                count[0] += block.count(OLD_PPR)
                block = block.replace(OLD_PPR, NEW_PPR)
            return block

        new_xml = TEXTBOX.sub(center_block, xml)
        if count[0]:
            items[n] = new_xml.encode("utf-8")
            touched[n] = count[0]

    if not touched:
        raise SystemExit("没有找到需要居中的页脚段落（可能已处理过）")

    with zipfile.ZipFile(TMP, "w", compression=zipfile.ZIP_DEFLATED) as zout:
        for n in names:
            zout.writestr(n, items[n])
    os.replace(TMP, TARGET)
    for k, v in touched.items():
        print(f"centered {k}: {v} 段")

    # 复核
    with zipfile.ZipFile(TARGET) as z:
        for n in touched:
            x = z.read(n).decode("utf-8")
            inner = TEXTBOX.findall(x)
            print(n, "| 文本框段落数:", len(inner),
                  "| 其中居中:", sum(1 for b in inner if 'w:jc w:val="center"' in b),
                  "| 仍不换行:", 'wrap="none"' in x)


if __name__ == "__main__":
    main()
