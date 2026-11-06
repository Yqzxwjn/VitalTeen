# -*- coding: utf-8 -*-
"""Report formatting details of key blocks so new content can match."""
from docx import Document
from docx.shared import Emu

path = r"D:\Code\VitalTeen\人工智能工具使用情况说明.docx"
doc = Document(path)

def fmt(p, tag):
    pf = p.paragraph_format
    print(f"--- {tag} style={p.style.name} align={p.alignment}")
    print(f"    indent first={pf.first_line_indent} left={pf.left_indent} right={pf.right_indent}")
    print(f"    space before={pf.space_before} after={pf.space_after} line={pf.line_spacing} rule={pf.line_spacing_rule}")
    for i, r in enumerate(p.runs[:3]):
        f = r.font
        rpr = r._element.rPr
        ea = None
        if rpr is not None and rpr.rFonts is not None:
            ea = rpr.rFonts.get('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}eastAsia')
        print(f"    run{i}: text={r.text[:14]!r} size={f.size.pt if f.size else None} name={f.name} ea={ea} bold={f.bold} color={f.color.rgb if f.color and f.color.rgb else None}")

paras = doc.paragraphs
for i in (2, 3, 19, 20, 33, 34, 35, 41, 42, 45):
    fmt(paras[i], f"paras[{i}]")

print("\n=== TABLE 0 ===")
t = doc.tables[0]
print("tblW/indent:", t._tbl.tblPr.xml[:600])
for r in t.rows[:2]:
    for c in r.cells:
        for p in c.paragraphs:
            print(f"  cell h={c.width} p.style={p.style.name} align={p.alignment} text={p.text[:20]!r}")
            for run in p.runs[:2]:
                print(f"     run size={run.font.size.pt if run.font.size else None} name={run.font.name} bold={run.font.bold}")
print("grid cols:", [c.width for c in t.columns])

print("\n=== TABLE 1 (T017 4 cols) ===")
t = doc.tables[1]
print("grid cols:", [c.width for c in t.columns])

print("\n=== STYLES: Body Text / Heading 1 ===")
for sname in ("Body Text", "Heading 1", "Normal"):
    s = doc.styles[sname]
    print(sname, "size=", s.font.size, "name=", s.font.name, "bold=", s.font.bold,
          "pf:", s.paragraph_format.first_line_indent, s.paragraph_format.space_before,
          s.paragraph_format.space_after, s.paragraph_format.line_spacing)

print("\n=== sectPr / page ===")
print(doc.sections[0].page_width.cm, doc.sections[0].page_height.cm,
      doc.sections[0].left_margin.cm, doc.sections[0].right_margin.cm,
      doc.sections[0].top_margin.cm, doc.sections[0].bottom_margin.cm)

print("\n=== numbering? ===")
numbering = doc.part.numbering_part
print("num ids:", [n.numId for n in numbering.element.findall('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}num')][:20])
