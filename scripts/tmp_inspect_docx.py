# -*- coding: utf-8 -*-
"""Dump the structure of the AI-usage statement DOCX."""
import sys
from docx import Document
from docx.shared import Emu

path = r"D:\Code\VitalTeen\人工智能工具使用情况说明.docx"
doc = Document(path)

print("=== SECTIONS ===")
for i, s in enumerate(doc.sections):
    print(f"[{i}] page={s.page_width}x{s.page_height} margins L{s.left_margin} R{s.right_margin} T{s.top_margin} B{s.bottom_margin}")
    print(f"    header={[p.text for p in s.header.paragraphs]} footer={[p.text for p in s.footer.paragraphs]}")

print("\n=== STYLES USED ===")
seen = {}
for p in doc.paragraphs:
    seen[p.style.name] = seen.get(p.style.name, 0) + 1
print(seen)

print("\n=== BODY (paragraphs + tables in order) ===")
from docx.table import Table
from docx.text.paragraph import Paragraph

def iter_block_items(parent):
    from docx.oxml.ns import qn
    body = parent.element.body
    for child in body.iterchildren():
        if child.tag == qn('w:p'):
            yield Paragraph(child, parent)
        elif child.tag == qn('w:tbl'):
            yield Table(child, parent)

idx = 0
for block in iter_block_items(doc):
    if isinstance(block, Paragraph):
        idx += 1
        has_img = 'graphic' in block._p.xml
        runs = [(r.text, r.bold, r.font.size.pt if r.font.size else None, r.font.name) for r in block.runs]
        print(f"P{idx:03d} [{block.style.name}] align={block.alignment} img={has_img} :: {block.text!r}")
        if len(runs) > 1:
            print(f"       runs={runs}")
    else:
        idx += 1
        print(f"T{idx:03d} TABLE rows={len(block.rows)} cols={len(block.columns)} style={block.style.name if block.style else None}")
        for r in block.rows:
            print("      | " + " | ".join(c.text.replace('\n', '\\n') for c in r.cells))

print("\n=== IMAGES (inline shapes) ===")
for i, shp in enumerate(doc.inline_shapes):
    print(f"[{i}] type={shp.type} w={shp.width} h={shp.height}")

print("\n=== DOC PROPERTIES ===")
cp = doc.core_properties
print(r"title=", cp.title, "| author=", cp.author, "| created=", cp.created, "| modified=", cp.modified)
