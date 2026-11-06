# -*- coding: utf-8 -*-
"""参赛补充材料的 DOCX 生成工具：A4、页脚页码、标题层级、表格、插图。"""

from docx import Document
from docx.enum.section import WD_SECTION
from docx.enum.table import WD_ALIGN_VERTICAL
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Emu, Pt, RGBColor

BODY_FONT = "宋体"
HEAD_FONT = "黑体"
TABLE_FONT = "仿宋"

INK = RGBColor(0x1F, 0x29, 0x37)
MUTED = RGBColor(0x60, 0x69, 0x76)
ACCENT = RGBColor(0x0B, 0x3D, 0x91)


def set_run(run, name=BODY_FONT, size=12, bold=None, color=None):
    run.font.name = name
    run.font.size = Pt(size)
    if bold is not None:
        run.font.bold = bold
    if color is not None:
        run.font.color.rgb = color
    rPr = run._element.get_or_add_rPr()
    rFonts = rPr.get_or_add_rFonts()
    for attr in ("w:ascii", "w:hAnsi", "w:eastAsia", "w:cs"):
        rFonts.set(qn(attr), name)


PPR_ORDER = ["w:pStyle", "w:keepNext", "w:keepLines", "w:pageBreakBefore", "w:framePr",
             "w:widowControl", "w:numPr", "w:suppressLineNumbers", "w:pBdr", "w:shd",
             "w:tabs", "w:suppressAutoHyphens", "w:kinsoku", "w:wordWrap",
             "w:overflowPunct", "w:topLinePunct", "w:autoSpaceDE", "w:autoSpaceDN",
             "w:bidi", "w:adjustRightInd", "w:snapToGrid", "w:spacing", "w:ind",
             "w:contextualSpacing", "w:mirrorIndents", "w:suppressOverlap", "w:jc",
             "w:textDirection", "w:textAlignment", "w:textboxTightWrap",
             "w:outlineLvl", "w:divId", "w:cnfStyle", "w:rPr", "w:sectPr", "w:pPrChange"]

TCPR_ORDER = ["w:cnfStyle", "w:tcW", "w:gridSpan", "w:hMerge", "w:vMerge", "w:tcBorders",
              "w:shd", "w:noWrap", "w:tcMar", "w:textDirection", "w:tcFitText",
              "w:vAlign", "w:hideMark"]


def insert_ordered(parent, child, order):
    """按 OOXML 规定的子元素顺序插入，避免 Word 打开时提示修复。"""
    tag = child.tag
    idx = order.index(tag) if tag in order else len(order)
    for existing in list(parent):
        etag = existing.tag
        eidx = order.index(etag) if etag in order else len(order)
        if eidx > idx:
            existing.addprevious(child)
            return child
    parent.append(child)
    return child


def shade(paragraph, fill="EEF3FA"):
    pPr = paragraph._p.get_or_add_pPr()
    shd = OxmlElement("w:shd")
    shd.set(qn("w:val"), "clear")
    shd.set(qn("w:color"), "auto")
    shd.set(qn("w:fill"), fill)
    insert_ordered(pPr, shd, PPR_ORDER)
    # 左侧色条
    pBdr = OxmlElement("w:pBdr")
    left = OxmlElement("w:left")
    left.set(qn("w:val"), "single")
    left.set(qn("w:sz"), "18")
    left.set(qn("w:space"), "8")
    left.set(qn("w:color"), "0B3D91")
    pBdr.append(left)
    insert_ordered(pPr, pBdr, PPR_ORDER)


def add_field(paragraph, instr, placeholder="1", size=10.5):
    run = paragraph.add_run()
    set_run(run, BODY_FONT, size)
    r = run._r
    f1 = OxmlElement("w:fldChar")
    f1.set(qn("w:fldCharType"), "begin")
    it = OxmlElement("w:instrText")
    it.set(qn("xml:space"), "preserve")
    it.text = f" {instr} "
    f2 = OxmlElement("w:fldChar")
    f2.set(qn("w:fldCharType"), "separate")
    t = OxmlElement("w:t")
    t.text = placeholder
    f3 = OxmlElement("w:fldChar")
    f3.set(qn("w:fldCharType"), "end")
    for el in (f1, it, f2, t, f3):
        r.append(el)


class Doc:
    """一份 A4 说明文档。"""

    def __init__(self, title, subject=""):
        self.d = Document()
        sec = self.d.sections[0]
        sec.page_width = Cm(21.0)
        sec.page_height = Cm(29.7)
        sec.left_margin = Cm(2.6)
        sec.right_margin = Cm(2.6)
        sec.top_margin = Cm(2.4)
        sec.bottom_margin = Cm(2.2)
        sec.footer_distance = Cm(1.4)
        self.width_cm = 21.0 - 5.2

        st = self.d.styles["Normal"]
        st.font.name = BODY_FONT
        st.font.size = Pt(12)
        st.element.rPr.rFonts.set(qn("w:eastAsia"), BODY_FONT)
        st.paragraph_format.space_after = Pt(0)
        st.paragraph_format.line_spacing_rule = WD_LINE_SPACING.ONE_POINT_FIVE

        cp = self.d.core_properties
        cp.title = title
        cp.subject = subject
        cp.author = "参赛团队"
        cp.comments = "匿名化评审材料"

        self._footer()

    def _footer(self):
        p = self.d.sections[0].footer.paragraphs[0]
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        r = p.add_run("第 ")
        set_run(r, BODY_FONT, 10.5, color=MUTED)
        add_field(p, "PAGE")
        r = p.add_run(" 页 共 ")
        set_run(r, BODY_FONT, 10.5, color=MUTED)
        add_field(p, "NUMPAGES")
        r = p.add_run(" 页")
        set_run(r, BODY_FONT, 10.5, color=MUTED)

    # ---------------------------------------------------------------- 结构
    def cover(self, kicker, title, subtitle, meta):
        for _ in range(3):
            self.d.add_paragraph()
        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        set_run(p.add_run(kicker), HEAD_FONT, 13, True, MUTED)

        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(10)
        set_run(p.add_run(title), HEAD_FONT, 26, True, ACCENT)

        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(6)
        set_run(p.add_run(subtitle), BODY_FONT, 13, False, INK)

        # 分隔线
        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        p.paragraph_format.space_before = Pt(18)
        pPr = p._p.get_or_add_pPr()
        pBdr = OxmlElement("w:pBdr")
        bottom = OxmlElement("w:bottom")
        bottom.set(qn("w:val"), "single")
        bottom.set(qn("w:sz"), "8")
        bottom.set(qn("w:space"), "1")
        bottom.set(qn("w:color"), "0B3D91")
        pBdr.append(bottom)
        insert_ordered(pPr, pBdr, PPR_ORDER)

        for k, v in meta:
            p = self.d.add_paragraph()
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(10)
            r1 = p.add_run(f"{k}：")
            set_run(r1, BODY_FONT, 11, True, MUTED)
            r2 = p.add_run(v)
            set_run(r2, BODY_FONT, 11, False, INK)

        p = self.d.add_paragraph()
        p.paragraph_format.space_before = Pt(60)
        self.note("本材料按赛事匿名化要求整理，不含参赛学校、团队名称、参赛学生与指导教师等可识别身份的信息。"
                  "文中以「成员A—成员E」指代团队成员。")

    def h1(self, text):
        p = self.d.add_paragraph()
        p.paragraph_format.space_before = Pt(16)
        p.paragraph_format.space_after = Pt(8)
        p.paragraph_format.keep_with_next = True
        set_run(p.add_run(text), HEAD_FONT, 16, True, ACCENT)

    def h2(self, text):
        p = self.d.add_paragraph()
        p.paragraph_format.space_before = Pt(10)
        p.paragraph_format.space_after = Pt(4)
        p.paragraph_format.keep_with_next = True
        set_run(p.add_run(text), HEAD_FONT, 13, True, INK)

    def h3(self, text):
        p = self.d.add_paragraph()
        p.paragraph_format.space_before = Pt(6)
        p.paragraph_format.space_after = Pt(2)
        p.paragraph_format.keep_with_next = True
        set_run(p.add_run(text), HEAD_FONT, 12, True, INK)

    def body(self, text, indent=True, space_after=4, size=12):
        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        pf = p.paragraph_format
        pf.first_line_indent = Pt(size * 2) if indent else Emu(0)
        pf.space_after = Pt(space_after)
        set_run(p.add_run(text), BODY_FONT, size, False, INK)
        return p

    def lead(self, head, rest):
        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        pf = p.paragraph_format
        pf.first_line_indent = Pt(24)
        pf.space_after = Pt(4)
        set_run(p.add_run(head), BODY_FONT, 12, True, INK)
        set_run(p.add_run(rest), BODY_FONT, 12, False, INK)
        return p

    def bullet(self, items, indent_cm=0.6, size=12):
        for it in items:
            p = self.d.add_paragraph()
            pf = p.paragraph_format
            pf.left_indent = Cm(indent_cm + 0.6)
            pf.first_line_indent = Cm(-0.6)
            pf.space_after = Pt(2)
            set_run(p.add_run("· "), BODY_FONT, size, True, ACCENT)
            set_run(p.add_run(it), BODY_FONT, size, False, INK)

    def note(self, text, size=10.5):
        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        pf = p.paragraph_format
        pf.left_indent = Cm(0.3)
        pf.space_before = Pt(4)
        pf.space_after = Pt(8)
        pf.line_spacing = 1.3
        shade(p)
        set_run(p.add_run(text), "仿宋", size, False, INK)
        return p

    def table(self, headers, rows, widths_cm=None, font_size=10.5, header_size=10.5,
              align=None, first_col_bold=True, row_height=None):
        ncol = len(headers)
        t = self.d.add_table(rows=1 + len(rows), cols=ncol)
        t.style = "Table Grid"
        t.autofit = False
        widths = widths_cm or [self.width_cm / ncol] * ncol
        for i, w in enumerate(widths):
            t.columns[i].width = Cm(w)
        for r in t.rows:
            for i, w in enumerate(widths):
                r.cells[i].width = Cm(w)

        trPr = t.rows[0]._tr.get_or_add_trPr()
        hdr = OxmlElement("w:tblHeader")
        hdr.set(qn("w:val"), "true")
        trPr.append(hdr)

        align = align or ["left"] * ncol
        amap = {"left": WD_ALIGN_PARAGRAPH.LEFT, "center": WD_ALIGN_PARAGRAPH.CENTER,
                "justify": WD_ALIGN_PARAGRAPH.JUSTIFY}

        for ci, text in enumerate(headers):
            cell = t.rows[0].cells[ci]
            cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            p = cell.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.paragraph_format.space_before = Pt(2)
            p.paragraph_format.space_after = Pt(2)
            p.paragraph_format.line_spacing = 1.15
            set_run(p.add_run(text), TABLE_FONT, header_size, True, INK)
            tcPr = cell._tc.get_or_add_tcPr()
            shd = OxmlElement("w:shd")
            shd.set(qn("w:val"), "clear")
            shd.set(qn("w:color"), "auto")
            shd.set(qn("w:fill"), "EEF3FA")
            insert_ordered(tcPr, shd, TCPR_ORDER)

        for ri, row in enumerate(rows, start=1):
            if row_height:
                t.rows[ri].height = Cm(row_height)
            for ci, text in enumerate(row):
                cell = t.rows[ri].cells[ci]
                cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
                p = cell.paragraphs[0]
                p.alignment = amap[align[ci]]
                p.paragraph_format.space_before = Pt(2)
                p.paragraph_format.space_after = Pt(2)
                p.paragraph_format.line_spacing = 1.15
                set_run(p.add_run(text), TABLE_FONT, font_size,
                        first_col_bold and ci == 0, INK)
        self.spacer(2)
        return t

    def figure(self, path, width_cm=None, caption=None):
        p = self.d.add_paragraph()
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        pf = p.paragraph_format
        pf.space_before = Pt(6)
        pf.space_after = Pt(2)
        pf.keep_with_next = True
        p.add_run().add_picture(path, width=Cm(width_cm or self.width_cm))
        if caption:
            c = self.d.add_paragraph()
            c.alignment = WD_ALIGN_PARAGRAPH.CENTER
            c.paragraph_format.space_after = Pt(10)
            set_run(c.add_run(caption), BODY_FONT, 9.5, False, MUTED)

    def figures_row(self, items, total_width_cm=None, gap_cm=0.4, caption=None):
        """并排多图（用表格排版，避免浮动锚点）。"""
        total = total_width_cm or self.width_cm
        n = len(items)
        w = (total - gap_cm * (n - 1)) / n
        t = self.d.add_table(rows=1, cols=n)
        t.autofit = False
        for i, (path, cap) in enumerate(items):
            cell = t.rows[0].cells[i]
            cell.width = Cm(w)
            cell.vertical_alignment = WD_ALIGN_VERTICAL.TOP
            p = cell.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            p.add_run().add_picture(path, width=Cm(w - 0.15))
            if cap:
                c = cell.add_paragraph()
                c.alignment = WD_ALIGN_PARAGRAPH.CENTER
                c.paragraph_format.space_before = Pt(3)
                set_run(c.add_run(cap), BODY_FONT, 9, False, MUTED)
        for i in range(n):
            t.columns[i].width = Cm(w)
        if caption:
            c = self.d.add_paragraph()
            c.alignment = WD_ALIGN_PARAGRAPH.CENTER
            c.paragraph_format.space_before = Pt(4)
            c.paragraph_format.space_after = Pt(10)
            set_run(c.add_run(caption), BODY_FONT, 9.5, False, MUTED)

    def spacer(self, pt=6):
        p = self.d.add_paragraph()
        p.paragraph_format.space_after = Pt(0)
        p.paragraph_format.line_spacing = 1
        set_run(p.add_run(""), BODY_FONT, max(pt / 2, 1))

    def page_break(self):
        self.d.add_page_break()

    def save(self, path):
        self.d.save(path)
        return path
