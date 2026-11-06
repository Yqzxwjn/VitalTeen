# -*- coding: utf-8 -*-
"""最终校验：字体设置、图片是否来自最新 PNG、结构完整性。"""
import hashlib
import os
import zipfile

from docx import Document
from docx.oxml.ns import qn

NEW = r"D:\Code\VitalTeen\人工智能工具使用情况说明（补充完成）.docx"
OLD = r"D:\Code\VitalTeen\人工智能工具使用情况说明_原始备份.docx"
FIGS = r"D:\Code\VitalTeen\ai-figures"


def md5(b):
    return hashlib.md5(b).hexdigest()


doc = Document(NEW)

# 1. 无字体/字号遗漏
bad = []
for p in doc.paragraphs:
    if not p.text.strip():
        continue
    for r in p.runs:
        if r.text.strip() and (r.font.size is None or r.font.name is None):
            bad.append((p.text[:26], r.text[:14], r.font.size, r.font.name))
print("缺字号/字体(正文段):", len(bad))
for b in bad[:6]:
    print("   ", b)

# 2. 图片二进制是否与 ai-figures 下最新 PNG 一致
with zipfile.ZipFile(NEW) as z:
    media = {n: z.read(n) for n in z.namelist() if n.startswith("word/media/")}
print("嵌入媒体数:", len(media))
fig_hashes = {}
for f in sorted(os.listdir(FIGS)):
    if f.lower().endswith(".png"):
        fig_hashes[md5(open(os.path.join(FIGS, f), "rb").read())] = f
for name, data in media.items():
    print(f"  {name}  {len(data)/1024:.0f} KB  -> {fig_hashes.get(md5(data), '来源未知')}")

# 3. 每张图所在段落居中、宽度合规
for i, s in enumerate(doc.inline_shapes):
    print(f"图{i+1}: {s.width.cm:.2f}x{s.height.cm:.2f} cm  type={s.type}")

# 4. 标题/小节层级
print("\n小节标题:")
for p in doc.paragraphs:
    if p.style.name == "Normal" and p.runs and p.runs[0].font.name == "黑体":
        print("   ", p.text)

# 5. 段落数、表格数、总字数
chars = sum(len(p.text) for p in doc.paragraphs)
for t in doc.tables:
    for row in t.rows:
        for c in row.cells:
            chars += len(c.text)
print(f"\n段落 {len(doc.paragraphs)} | 表格 {len(doc.tables)} | 图片 {len(doc.inline_shapes)} | 字符约 {chars}")
print("文件大小 %.2f MB" % (os.path.getsize(NEW) / 1024 / 1024))

# 6. 交叉引用检查：文中提到的“图 1/2/3”是否存在
body = "\n".join(p.text for p in doc.paragraphs)
for k in ("图 1", "图 2", "图 3"):
    print(f"  提到 {k}: {body.count(k)} 次")
