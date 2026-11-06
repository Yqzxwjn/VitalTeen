# -*- coding: utf-8 -*-
"""校验生成结果：原有段落是否保留、新增内容顺序、图片与表格数量。"""
from docx import Document
from docx.oxml.ns import qn
from docx.table import Table
from docx.text.paragraph import Paragraph

NEW = r"D:\Code\VitalTeen\人工智能工具使用情况说明（补充完成）.docx"
OLD = r"D:\Code\VitalTeen\人工智能工具使用情况说明_原始备份.docx"


def blocks(doc):
    out = []
    for child in doc.element.body.iterchildren():
        if child.tag == qn("w:p"):
            p = Paragraph(child, doc)
            out.append(("P", p.style.name, p.text, "graphic" in child.xml))
        elif child.tag == qn("w:tbl"):
            t = Table(child, doc)
            out.append(("T", t.style.name if t.style else "", f"{len(t.rows)}x{len(t.columns)}", False))
    return out


old, new = Document(OLD), Document(NEW)
ob, nb = blocks(old), blocks(new)

print(f"blocks: old={len(ob)} new={len(nb)}")
print(f"inline shapes: old={len(old.inline_shapes)} new={len(new.inline_shapes)}")
print(f"tables: old={len(old.tables)} new={len(new.tables)}")

old_texts = [b[2] for b in ob if b[0] == "P" and b[2].strip()]
new_texts = [b[2] for b in nb if b[0] == "P" and b[2].strip()]
missing = [t for t in old_texts if t not in new_texts]
print("缺失的原有段落:", len(missing))
for m in missing[:5]:
    print("   !", m[:60])

print("\n=== 新增块 ===")
old_set = set(old_texts)
for idx, b in enumerate(nb):
    if b[0] == "P" and b[2] in old_set:
        continue
    if b[0] == "P":
        tag = " [图]" if b[3] else ""
        print(f"{idx:3d} P{tag} [{b[1]}] {b[2][:70]}")
    else:
        print(f"{idx:3d} TABLE [{b[2]}]")

print("\n=== 图片尺寸 ===")
for s in new.inline_shapes:
    print(f"  {s.width.cm:.2f} x {s.height.cm:.2f} cm")

sec = new.sections[0]
print(f"\n页面可用宽度 {sec.page_width.cm - sec.left_margin.cm - sec.right_margin.cm:.2f} cm")

print("\n=== 新增表格列宽 ===")
for t in new.tables[3:]:
    print("  ", [round(c.width.cm, 2) if c.width else None for c in t.columns], "| header:",
          " / ".join(c.text for c in t.rows[0].cells))
