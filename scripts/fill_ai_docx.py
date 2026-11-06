# -*- coding: utf-8 -*-
"""把补充内容与示意图写入《人工智能工具使用情况说明.docx》。

原则：沿用原文档的样式与排版（Body Text / 1.5 倍行距 / 首行缩进 / 宋体 12pt），
新增内容按锚点段落插入，不重建既有章节。
"""

import os
import shutil

from docx import Document
from docx.enum.table import WD_ALIGN_VERTICAL
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_LINE_SPACING
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Emu, Pt

SRC = r"D:\Code\VitalTeen\人工智能工具使用情况说明.docx"
BAK = r"D:\Code\VitalTeen\人工智能工具使用情况说明_原始备份.docx"
OUT = r"D:\Code\VitalTeen\人工智能工具使用情况说明（补充完成）.docx"
FIG_DIR = r"D:\Code\VitalTeen\ai-figures"

CONTENT_W = Cm(16.39)
INDENT = Emu(304800)


# ---------------------------------------------------------------- 基础工具
def set_run(run, name="宋体", size=12, bold=None, color=None):
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


def new_paragraph(doc, style="Body Text"):
    p = doc.add_paragraph(style=style)
    return p


def place(p, anchor):
    """把段落到 anchor 之前。"""
    anchor._p.addprevious(p._p)


class Inserter:
    def __init__(self, doc):
        self.doc = doc
        self.anchor = None

    def at(self, anchor):
        self.anchor = anchor
        return self

    # ---- 正文段
    def body(self, text, size=12, font="宋体", indent=True, align=WD_ALIGN_PARAGRAPH.JUSTIFY,
             space_after=0, bold=None, line=1.5):
        p = new_paragraph(self.doc)
        p.alignment = align
        pf = p.paragraph_format
        pf.first_line_indent = INDENT if indent else Emu(0)
        pf.left_indent = Emu(0)
        pf.space_before = Pt(0)
        pf.space_after = Pt(space_after)
        pf.line_spacing_rule = WD_LINE_SPACING.ONE_POINT_FIVE if line == 1.5 else WD_LINE_SPACING.SINGLE
        run = p.add_run(text)
        set_run(run, font, size, bold)
        place(p, self.anchor)
        return p

    # ---- 带引导语加粗的正文段
    def body_lead(self, lead, rest, size=12):
        p = new_paragraph(self.doc)
        p.alignment = WD_ALIGN_PARAGRAPH.JUSTIFY
        pf = p.paragraph_format
        pf.first_line_indent = INDENT
        pf.left_indent = Emu(0)
        pf.space_before = Pt(0)
        pf.space_after = Pt(0)
        pf.line_spacing_rule = WD_LINE_SPACING.ONE_POINT_FIVE
        r1 = p.add_run(lead)
        set_run(r1, "宋体", size, True)
        r2 = p.add_run(rest)
        set_run(r2, "宋体", size, False)
        place(p, self.anchor)
        return p

    # ---- 小节标题
    def subhead(self, text, size=12):
        p = new_paragraph(self.doc, style="Normal")
        p.alignment = WD_ALIGN_PARAGRAPH.LEFT
        pf = p.paragraph_format
        pf.first_line_indent = Emu(0)
        pf.left_indent = Emu(0)
        pf.space_before = Pt(8)
        pf.space_after = Pt(4)
        pf.line_spacing_rule = WD_LINE_SPACING.ONE_POINT_FIVE
        pf.keep_with_next = True
        r = p.add_run(text)
        set_run(r, "黑体", size, True)
        place(p, self.anchor)
        return p

    # ---- 图
    def figure(self, filename, width_cm=16.2):
        path = os.path.join(FIG_DIR, filename)
        p = new_paragraph(self.doc)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        pf = p.paragraph_format
        pf.first_line_indent = Emu(0)
        pf.left_indent = Emu(0)
        pf.space_before = Pt(8)
        pf.space_after = Pt(2)
        pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
        pf.keep_with_next = True
        p.add_run().add_picture(path, width=Cm(width_cm))
        place(p, self.anchor)
        return p

    def caption(self, text, size=10.5):
        p = new_paragraph(self.doc)
        p.alignment = WD_ALIGN_PARAGRAPH.CENTER
        pf = p.paragraph_format
        pf.first_line_indent = Emu(0)
        pf.left_indent = Emu(0)
        pf.space_before = Pt(0)
        pf.space_after = Pt(12)
        pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
        r = p.add_run(text)
        set_run(r, "宋体", size, False)
        place(p, self.anchor)
        return p

    # ---- 表格
    def table(self, headers, rows, widths_cm, font_size=10.5, header_size=10.5, align=None):
        ncol = len(headers)
        t = self.doc.add_table(rows=1 + len(rows), cols=ncol)
        t.style = "Table Grid"
        t.autofit = False  # python-docx 会写入固定版式的 tblLayout

        align = align or ["left"] * ncol
        for i, w in enumerate(widths_cm):
            t.columns[i].width = Cm(w)
        for r in t.rows:
            for i, w in enumerate(widths_cm):
                r.cells[i].width = Cm(w)
            r._tr.get_or_add_trPr()

        # 表头重复
        trPr = t.rows[0]._tr.get_or_add_trPr()
        hdr = OxmlElement("w:tblHeader")
        hdr.set(qn("w:val"), "true")
        trPr.append(hdr)

        for ci, text in enumerate(headers):
            cell = t.rows[0].cells[ci]
            cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
            p = cell.paragraphs[0]
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER
            pf = p.paragraph_format
            pf.first_line_indent = Emu(0)
            pf.space_before = Pt(2)
            pf.space_after = Pt(2)
            pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
            set_run(p.add_run(text), "仿宋", header_size, True)

        for ri, row in enumerate(rows, start=1):
            for ci, text in enumerate(row):
                cell = t.rows[ri].cells[ci]
                cell.vertical_alignment = WD_ALIGN_VERTICAL.CENTER
                p = cell.paragraphs[0]
                p.alignment = {"left": WD_ALIGN_PARAGRAPH.LEFT,
                               "center": WD_ALIGN_PARAGRAPH.CENTER,
                               "justify": WD_ALIGN_PARAGRAPH.JUSTIFY}[align[ci]]
                pf = p.paragraph_format
                pf.first_line_indent = Emu(0)
                pf.space_before = Pt(2)
                pf.space_after = Pt(2)
                pf.line_spacing_rule = WD_LINE_SPACING.SINGLE
                set_run(p.add_run(text), "仿宋", font_size, ci == 0)

        self.anchor._p.addprevious(t._tbl)
        # 表后留一点空隙（表格后紧跟段落时排版更稳）
        return t


def find_paragraph(doc, prefix):
    hits = [p for p in doc.paragraphs if p.text.strip().startswith(prefix)]
    if len(hits) != 1:
        raise SystemExit(f"锚点应唯一: {prefix!r} -> {len(hits)} 个")
    return hits[0]


# ---------------------------------------------------------------- 正文内容
def main():
    if not os.path.exists(BAK):
        shutil.copy2(SRC, BAK)
    else:
        print("backup exists:", BAK)
    doc = Document(SRC)
    ins = Inserter(doc)

    # 锚点：四、六、七 章节标题、八 以及七(四) 之后的示例段
    a4 = find_paragraph(doc, "四、最终成果中的AI生成或辅助内容")
    a6 = find_paragraph(doc, "六、代表性过程材料（按需）")
    a7 = find_paragraph(doc, "七、资源来源与合规说明")
    a8 = find_paragraph(doc, "八、填写确认与提交提示")
    a_third = find_paragraph(doc, "【第三方资源使用情况填写示例（按需）】")
    print("anchors ok:", a4.text[:8], a6.text[:8], a7.text[:8], a8.text[:8], a_third.text[:8])

    # ============ 三、代表性AI使用过程：收尾 ============
    ins.at(a4)
    ins.subhead("三个环节的共同做法")
    ins.body("三个环节的对象不同，工作方式却遵循同一条原则：AI 只负责把「空白」推到「有初稿」的位置，团队负责把初稿变成「敢署名」的成果。具体可以归纳为三点。")
    ins.body_lead("一是输入先给约束。",
                  "提示词中写明读者年龄、篇幅、语气、可用素材与技术栈，并要求分步骤输出、对没有把握的地方显式标注。约束给得越具体，得到的结果越接近可用，后续返工也越少。")
    ins.body_lead("二是输出必须过筛。",
                  "任何一段文字、一行代码、一张图，都要先经过团队判断：能否说清依据、是否符合本项目规则、是否经得起追问。说不清的就退回重做，不因为「已经生成了」而将就使用。")
    ins.body_lead("三是结果必须可验证。",
                  "科普文字对照专业文献核对，代码必须跑通测试，配图要放回真实页面看效果。验证不通过的产物一律不进作品。")
    ins.body("需要说明的是，本说明的重点不是「用了多少次 AI」，而是「AI 在哪里停下来」。团队把 AI 的作用范围限定在草稿、参考与灵感三个位置；凡是涉及体态判定标准、动作规则、阈值、矫正方案选择与最终文案定稿的部分，均由团队独立完成并承担相应责任。")

    # ============ 五、学生原创贡献说明：工作清单 ============
    ins.at(a6)
    ins.subhead("学生自主完成的主要工作清单")
    ins.body("为避免把 AI 的辅助作用与团队的实际工作混为一谈，以下按模块列出团队独立完成的主要内容，以及 AI 在该模块中的参与程度。")
    ins.table(
        ["模块", "团队自主完成的主要内容", "AI 参与程度"],
        [
            ["产品构思与需求调研", "面向 12—18 岁青少年的体态问题调研，确定「测—评—练—督」闭环与平台定位，完成作品命名与赛道适配", "未使用"],
            ["领域层规则设计", "31 个特征算子、动作状态机、错误分类规则与阈值治理框架；9 个动作的判定逻辑", "未使用"],
            ["端侧双语言实现", "Dart 端侧移植与 Python 参考实现逐值对齐；摄像头、语音、报告渲染与断网本机判定", "未使用"],
            ["决策服务", "决策契约、候选集构造、方案库、文案模板、降级与弃权路径", "未使用"],
            ["数据可视化大屏", "数据契约与校验、地图加载与省名归一化、五个视图与点击下钻交互", "未使用"],
            ["前端界面与交互", "页面结构、组件拆分、状态管理、响应式与可访问性处理", "仅思路参考"],
            ["科普内容", "选题、文献核对、通俗化改写与终稿定稿", "初稿参考"],
            ["视觉与品牌", "配色体系、图形规范、页面配图与全站统一风格", "灵感参考"],
            ["演示视频", "脚本撰稿、实机录屏、剪辑、字幕与节奏控制", "框架参考"],
        ],
        widths_cm=[3.5, 9.1, 3.7],
        font_size=10.5,
        align=["left", "justify", "center"],
    )
    ins.body("表中「未使用」指该模块的方案与实现均由团队完成；「参考」指 AI 输出只作为起点，最终产物由团队重写或重做，不保留原始生成结果。", space_after=0)

    # ============ 六、代表性过程材料 ============
    ins.at(a7)
    ins.subhead("（一）材料构成")
    ins.body("本节保留三类材料，分别回答三个问题：AI 用在了哪里、模型能做到哪一步、什么样的 AI 输出才允许进入作品。三幅示意图均由团队自行绘制，配合文字说明 AI 在流程中的确切位置；原始提示词、对话记录与版本对比材料已按环节归档留存，如评审需要核查，可按赛事要求单独提供。")
    ins.body("涉及真机画面、真实用户与账号信息的截图未随文附上，相关处理说明见第七部分。")

    ins.subhead("（二）AI 参与环节与人工接管节点")
    ins.body("图 1 按四类工作梳理 AI 的介入位置与团队的接管节点。四行的结构一致：团队给出任务与约束，AI 产出草稿或参考，团队完成判断、重写与验证，成果落到平台上具体的模块。")
    ins.figure("fig1-human-ai-division.png")
    ins.caption("图 1　AI 参与环节与人工接管节点（团队自绘）")
    ins.body("需要强调最后一列：AI 的产出并不直接对应任何上线模块。知识库文本经过逐条医学核对与重写，代码片段经过重新实现与测试，配图经过二次调整，演示视频中的画面全部来自平台实机录屏。AI 的作用体现在过程中的草稿与参考，而不在最终作品的面貌上。")

    ins.subhead("（三）从姿态帧到导引反馈：模型在哪里，边界在哪里")
    ins.body("图 2 给出平台实际的数据链路。手机端完成关键点推理、滤波、特征计算与规则判定，只把结构化特征与质量指标上传；服务端在封闭的候选集内完成选择、评分与门控，再结合方案库与文案模板输出可读的导引建议。")
    ins.figure("fig2-model-boundary.png")
    ins.caption("图 2　端侧计算与服务端决策的数据链路（团队自绘）")
    ins.body("这条链路上有几处刻意设定的人为约束。其一，模型不接触视频、像素与关键点，只面对已经算好的特征与候选错误，因此它无法「看到」任何画面，也无法自行发明判定标准。其二，候选集封闭在 4—6 类错误与 5—10 条方案之间，选项顺序随机化并记录随机种子，以规避模型对选项位置的偏好。其三，置信度不足时系统弃权并提示重录，宁可不给结论，也不编造确定性。其四，阈值与方案库由团队与体育专业成员维护，模型不得新增候选、不得修改阈值。这些约束都在设计阶段由团队确定，AI 在其中承担的只是「在给定选项里择优」这一步。")

    ins.subhead("（四）AI 输出的准入门槛")
    ins.body("图 3 是团队对 AI 输出的四道检查，既是开发时的操作习惯，也是本次参赛对每一处生成内容的自查标准。")
    ins.figure("fig3-admission-gates.png")
    ins.caption("图 3　AI 输出的四道准入门槛（团队自绘）")
    ins.body("第三道检查值得单独说明。项目的领域层有 Python 与 Dart 两份实现，两者算出的特征若不一致，模型会在无人察觉的情况下失效，这是本项目最隐蔽也最危险的一类问题。团队因此把 10 组场景、31 个特征的 golden fixtures 作为跨语言的唯一裁判，任何一侧的改动都要两侧同时通过才算完成。这条规则对 AI 给出的代码片段同样适用：片段看起来再合理，也必须先过这套比对。")

    ins.subhead("（五）提示词构造与实际做法")
    ins.body("使用过程中，团队逐步固定了一套提示词结构。目的不是追求「一次生成就能用」，而是让 AI 的输出更容易被核查、被接手。")
    ins.table(
        ["提示词要素", "具体做法", "作用"],
        [
            ["读者与场景", "明确读者为 12—18 岁青少年及其家长，限定篇幅、分段方式与语气，避免专业术语堆叠", "控制语域，减少二次改写"],
            ["任务与依据", "一次只交办一件事，并附上文献要点、平台真实功能清单或报错日志，要求只在此基础上作答", "让结论可回溯到依据"],
            ["不确定处标注", "要求对没有把握的数据、机制与结论显式标注「未核实」", "便于人工优先核查风险点"],
            ["输出格式", "文字给出成因、影响、建议三段；代码说明改动点、影响范围与验证方式", "降低接手成本"],
            ["迭代方式", "按「哪里不对、为什么不对、应该怎样」逐轮修正，而不是整段重写", "保留可追溯的修改轨迹"],
        ],
        widths_cm=[3.6, 8.4, 4.3],
        font_size=10.5,
        align=["left", "justify", "left"],
    )
    ins.body("按这套结构使用后，最直接的变化是需要推翻重来的次数明显减少：多数返工都集中在个别表述与参数，而不是整篇重写。", space_after=0)

    ins.subhead("（六）材料清点")
    ins.body("本说明随文附示意图 3 幅，均标注为团队自绘；正文中的表格由团队依据实际开发记录整理。原始提示词、对话记录、报错日志与版本对比材料已按环节归档留存，可应要求提供；涉及账号、密钥与他人信息的部分，在留存时即完成脱敏。")

    # ============ 七、合规说明：未成年人数据 ============
    ins.at(a_third)
    ins.subhead("（五）未成年人数据与 AI 服务的合规处理")
    ins.body("平台面向未成年人，数据合规是设计前提而不是事后补丁。团队在架构上做了三条限制：视频帧不离开设备，端侧算完特征即丢弃原始画面，只上传结构化特征与判定结果；报告中不出现可识别身份的信息，练习历史仅保存在本机；演示视频与截图里的人脸、姓名、账号与密钥一律脱敏。")
    ins.body("对 AI 生成内容，团队按「可核查、可追溯、可替换」处理：保留生成与修改的对照材料，对进入作品的每一处 AI 辅助内容都能说明来源与人工处理方式；不使用 AI 生成内容冒充学生原创，也不把模型输出直接作为医学建议对外呈现。系统在数据不足或置信度偏低时会弃权并提示重录，而不是给出看似确定的结论。")

    # ============ 顺手修正的重复字 ============
    fixed = []
    for t in doc.tables:
        for row in t.rows:
            for cell in row.cells:
                for p in cell.paragraphs:
                    for run in p.runs:
                        if "体态报告体态报告" in run.text:
                            run.text = run.text.replace("体态报告体态报告", "体态报告")
                            fixed.append("体态报告体态报告")
                        if "全有由团队" in run.text:
                            run.text = run.text.replace("全有由团队", "全部由团队")
                            fixed.append("全有由团队")
    for p in doc.paragraphs:
        for run in p.runs:
            if run.text.startswith("是平台真实运行的录屏"):
                run.text = run.text.replace("是平台真实运行的录屏", "平台真实运行的录屏", 1)
                fixed.append("均为是平台")
            if run.text.startswith("要求以“AI占比”"):
                run.text = "不" + run.text
                fixed.append("特别提示：不要求以")
    print("typo fixes:", fixed)

    doc.save(OUT)
    print("saved", OUT)


if __name__ == "__main__":
    main()
