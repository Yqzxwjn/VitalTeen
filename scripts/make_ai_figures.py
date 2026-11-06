# -*- coding: utf-8 -*-
"""生成《人工智能工具使用情况说明》配套示意图（PIL 绘制，无外部依赖）。"""
import os
from PIL import Image, ImageDraw, ImageFont

OUT_DIR = r"D:\Code\VitalTeen\ai-figures"
S = 2  # 超采样倍数

FONT_REG = r"C:\Windows\Fonts\msyh.ttc"
FONT_BD = r"C:\Windows\Fonts\msyhbd.ttc"

INK = (31, 41, 55)
MUTED = (96, 105, 118)
BLUE = (11, 61, 145)
SKY = (0, 152, 208)
GREEN = (76, 148, 22)
ORANGE = (222, 120, 10)
GREY_BORDER = (203, 213, 225)
GREY_FILL = (246, 247, 249)
SKY_T = (233, 246, 253)
GREEN_T = (242, 249, 234)
ORANGE_T = (254, 244, 230)
BLUE_T = (236, 242, 251)

_cache = {}


def font(size, bold=False):
    key = (size, bold)
    if key not in _cache:
        _cache[key] = ImageFont.truetype(FONT_BD if bold else FONT_REG, int(size * S))
    return _cache[key]


def new_canvas(w, h):
    img = Image.new("RGB", (w * S, h * S), "white")
    return img, ImageDraw.Draw(img)


def sc(v):
    return int(round(v * S))


def wrap(text, fnt, max_w, draw):
    """按字符折行（中文逐字可断），max_w 为设计坐标宽度。"""
    limit = max_w * S
    lines, cur = [], ""
    for ch in text:
        if ch == "\n":
            lines.append(cur)
            cur = ""
            continue
        trial = cur + ch
        if draw.textlength(trial, font=fnt) <= limit:
            cur = trial
        else:
            if cur == "":
                lines.append(ch)
                cur = ""
            else:
                lines.append(cur)
                cur = ch
    if cur:
        lines.append(cur)
    return lines


TEXT_RECTS = []


def check_layout():
    """确保文字区域互不重叠、且都在画布内。"""
    for i in range(len(TEXT_RECTS)):
        x, y, w, h = TEXT_RECTS[i]
        for j in range(i + 1, len(TEXT_RECTS)):
            x2, y2, w2, h2 = TEXT_RECTS[j]
            ox = min(x + w, x2 + w2) - max(x, x2)
            oy = min(y + h, y2 + h2) - max(y, y2)
            if ox > 2 and oy > 2:
                raise ValueError(f"text overlap: {TEXT_RECTS[i]} vs {TEXT_RECTS[j]}")
    TEXT_RECTS.clear()


def text_block(draw, x, y, w, h, lines, fnt, fill=INK, gap=1.42, align="left", valign="middle"):
    lh = fnt.size * gap / S
    total = lh * len(lines)
    if total > h + 0.5:
        raise ValueError(f"text overflow: {total:.1f} > {h}: {lines}")
    if valign == "middle":
        top = y + (h - total) / 2
    elif valign == "bottom":
        top = y + h - total
    else:
        top = y
    for i, line in enumerate(lines):
        lw = draw.textlength(line, font=fnt) / S
        if lw > w + 2:
            raise ValueError(f"line too wide ({lw:.0f}>{w}): {line!r}")
        if align == "center":
            tx = x + (w - lw) / 2
        elif align == "right":
            tx = x + w - lw
        else:
            tx = x
        draw.text((sc(tx), sc(top + i * lh + (lh - fnt.size / S) / 2)), line, font=fnt, fill=fill)
    TEXT_RECTS.append((x, top, w, total))
    return total


def block(draw, x, y, w, h, fill, border, radius=18, width=3):
    draw.rounded_rectangle([sc(x), sc(y), sc(x + w), sc(y + h)], radius=sc(radius),
                           fill=fill, outline=border, width=sc(width))


def arrow(draw, x1, y1, x2, y2, color=MUTED, width=4, head=16):
    draw.line([sc(x1), sc(y1), sc(x2), sc(y2)], fill=color, width=sc(width))
    if abs(y2 - y1) < 1:  # 水平
        d = 1 if x2 > x1 else -1
        pts = [(x2, y2), (x2 - d * head, y2 - head * 0.55), (x2 - d * head, y2 + head * 0.55)]
    else:  # 垂直
        d = 1 if y2 > y1 else -1
        pts = [(x2, y2), (x2 - head * 0.55, y2 - d * head), (x2 + head * 0.55, y2 - d * head)]
    draw.polygon([(sc(a), sc(b)) for a, b in pts], fill=color)


def dashed_v(draw, x, y1, y2, color=SKY, width=3, dash=18, gap=12):
    y = y1
    while y < y2:
        draw.line([sc(x), sc(y), sc(x), sc(min(y + dash, y2))], fill=color, width=sc(width))
        y += dash + gap


def save(img, name):
    check_layout()
    # 边缘 4px 内不应有内容：出现即说明有文字/图形被裁切
    margin = 4 * S
    w, h = img.size
    px = img.load()
    for y in range(h):
        for x in list(range(margin)) + list(range(w - margin, w)):
            if px[x, y] != (255, 255, 255):
                raise ValueError(f"border clipping at ({x},{y}) in {name}")
    for x in range(w):
        for y in list(range(margin)) + list(range(h - margin, h)):
            if px[x, y] != (255, 255, 255):
                raise ValueError(f"border clipping at ({x},{y}) in {name}")
    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, name)
    img.resize((img.width // S, img.height // S), Image.LANCZOS).save(path, "PNG", optimize=True)
    print(f"saved {path}  {img.width // S}x{img.height // S}")


# ----------------------------------------------------------------------------
# 图 1：AI 参与环节与人工接管节点
# ----------------------------------------------------------------------------
def figure1():
    W, H = 2400, 1720
    img, d = new_canvas(W, H)

    cols = [(43, 448), (529, 618), (1185, 660), (1883, 468)]
    heads = ["任务输入与约束", "AI 工具与输出", "学生处理与复核", "最终落点"]
    head_cols = [MUTED, SKY, GREEN, ORANGE]
    for (x, w), t, c in zip(cols, heads, head_cols):
        d.text((sc(x), sc(38)), t, font=font(38, True), fill=c)

    rows = [
        ("① 科普内容", "面向 12—18 岁的体态科普选题、受众定位与文献要点",
         "DeepSeek-V4.1-Flash", "按选题生成 2—3 版科普短文草稿，含成因、影响、建议三段结构",
         "逐条核对医学说法，删去无依据的表述，重写并压缩为网页阅读篇幅",
         "平台【健康知识库】文本"),
        ("② 程序开发", "团队自写代码、程序报错日志与待实现的业务功能说明",
         "Claude Code（DeepSeek-V4.1-Flash）", "给出改动思路、排错方向与代码片段参考，不直接产出整模块",
         "判断是否适用于本项目规则，按自有业务逻辑重写，跑通测试后才合并",
         "Web 前后端与端侧判定模块"),
        ("③ 视觉设计", "页面风格、配色基调与配图需求描述",
         "AI 图像生成工具", "输出多版插图与界面效果图，用于构图与氛围参考",
         "挑选稿子，调整色彩与图形，统一全站风格；仅借鉴思路，不直接用原图",
         "首页与知识库配图"),
        ("④ 演示视频", "平台真实功能清单与实机录屏素材",
         "DeepSeek-V4.1-Flash", "生成脚本框架与分镜顺序建议",
         "重新撰写台词，按真实录屏排布镜头、字幕与节奏",
         "参赛演示视频"),
    ]

    y0, rh, gap = 108, 340, 34
    fills = [(GREY_FILL, GREY_BORDER), (SKY_T, SKY), (GREEN_T, GREEN), (ORANGE_T, ORANGE)]
    for i, rt in enumerate(rows):
        y = y0 + i * (rh + gap)
        for j, (x, w) in enumerate(cols):
            fill, border = fills[j]
            block(d, x, y, w, rh, fill, border, radius=20, width=3)
            pad = 26
            if j == 0:
                text_block(d, x + pad, y + pad, w - 2 * pad, rh - 2 * pad,
                           [rt[0]] + wrap(rt[1], font(29), w - 2 * pad, d), font(29), INK, gap=1.5)
            elif j == 1:
                text_block(d, x + pad, y + pad, w - 2 * pad, rh - 2 * pad,
                           [rt[2]] + wrap(rt[3], font(29), w - 2 * pad, d), font(29), INK, gap=1.5)
            elif j == 2:
                text_block(d, x + pad, y + pad, w - 2 * pad, rh - 2 * pad,
                           wrap(rt[4], font(29), w - 2 * pad, d), font(29), INK, gap=1.5)
            else:
                text_block(d, x + pad, y + pad, w - 2 * pad, rh - 2 * pad,
                           wrap(rt[5], font(29), w - 2 * pad, d), font(29), INK, gap=1.5)

        # 列间箭头
        for j in range(3):
            x1 = cols[j][0] + cols[j][1]
            x2 = cols[j + 1][0]
            arrow(d, x1 + 6, y + rh / 2, x2 - 6, y + rh / 2, MUTED, width=4, head=14)

        # 行标签竖线
        d.line([sc(26), sc(y + 10), sc(26), sc(y + rh - 10)], fill=GREY_BORDER, width=sc(6))

    # 图例
    ly = y0 + 4 * (rh + gap) + 12
    items = [("AI 输出：仅作草稿与参考", SKY), ("学生处理：判断 · 重写 · 验证", GREEN), ("最终落点：作品中的实际位置", ORANGE)]
    lx = 43
    for t, c in items:
        block(d, lx, ly + 4, 34, 26, c, c, radius=8, width=1)
        d.text((sc(lx + 50), sc(ly)), t, font=font(31), fill=MUTED)
        lx += 50 + d.textlength(t, font=font(31)) / S + 60

    save(img, "fig1-human-ai-division.png")


# ----------------------------------------------------------------------------
# 图 2：端侧到服务端的数据链路与模型边界
# ----------------------------------------------------------------------------
def figure2():
    W, H = 2400, 1180
    img, d = new_canvas(W, H)

    margin, bw, gap = 50, 706, 50
    xs = [margin + i * (bw + gap) for i in range(3)]

    # 端侧
    block(d, 40, 62, 2320, 400, GREEN_T, GREEN, radius=26, width=3)
    d.text((sc(72), sc(84)), "端侧 · 手机本地计算", font=font(36, True), fill=GREEN)

    ondevice = [
        ("姿态采集", "摄像头逐帧推理，输出 33 个骨骼关键点与可见性"),
        ("滤波与特征", "三级滤波防抖；像素坐标下计算 31 个特征"),
        ("状态机与规则", "动作相位判定、错误分类，输出候选错误集"),
    ]
    for i, (t, s) in enumerate(ondevice):
        x = xs[i]
        block(d, x, 150, bw, 270, (255, 255, 255), GREEN, radius=18, width=3)
        lines = [t] + wrap(s, font(29), bw - 52, d)
        text_block(d, x + 26, 176, bw - 52, 230, lines, font(29), INK, gap=1.5)
        if i < 2:
            arrow(d, x + bw + 8, 285, x + bw + gap - 8, 285, GREEN, width=4, head=14)

    # 传输层
    arrow(d, 1200, 470, 1200, 560, SKY, width=6, head=20)
    d.text((sc(1240), sc(492)), "只传结构化特征 JSON：关键点坐标、特征、置信度、质量指标", font=font(31), fill=SKY)
    d.text((sc(1240), sc(534)), "视频帧与原始画面不出设备", font=font(31, True), fill=SKY)

    # 服务端
    block(d, 40, 600, 2320, 400, BLUE_T, BLUE, radius=26, width=3)
    d.text((sc(72), sc(622)), "服务端 · 决策与文案", font=font(36, True), fill=BLUE)

    server = [
        ("决策契约", "候选错误集封闭（4—6 类），顺序随机化并记录种子"),
        ("Laya 轻量决策", "在给定候选内选择主问题、评分、门控，置信不足则弃权"),
        ("报告与方案", "文案模板 + 矫正方案库，输出青少年可读的导引"),
    ]
    for i, (t, s) in enumerate(server):
        x = xs[i]
        block(d, x, 688, bw, 270, (255, 255, 255), BLUE, radius=18, width=3)
        lines = [t] + wrap(s, font(29), bw - 52, d)
        text_block(d, x + 26, 714, bw - 52, 230, lines, font(29), INK, gap=1.5)
        if i < 2:
            arrow(d, x + bw + 8, 823, x + bw + gap - 8, 823, BLUE, width=4, head=14)

    # 注释
    notes = [
        "模型不接触视频、像素与关键点，也不计算任何几何量；判定依据来自团队设计的规则与阈值。",
        "74 条体育阈值的核定权归体育专业成员，未核定项只出提示、不参与扣分。",
    ]
    ny = 1030
    for n in notes:
        d.text((sc(46), sc(ny)), "·", font=font(32, True), fill=SKY)
        for k, line in enumerate(wrap(n, font(29), 2280, d)):
            d.text((sc(76), sc(ny + k * 42)), line, font=font(29), fill=MUTED)
        ny += 42 * len(wrap(n, font(29), 2280, d)) + 6

    save(img, "fig2-model-boundary.png")


# ----------------------------------------------------------------------------
# 图 3：AI 输出的四道准入门槛
# ----------------------------------------------------------------------------
def figure3():
    W, H = 2400, 1120
    img, d = new_canvas(W, H)

    steps = [
        ("检查一 · 事实核对", "医学说法逐条对照专业文献；代码片段对照官方文档与既有接口。查不到依据的表述一律删除，不保留“大概如此”的内容。", SKY_T, SKY),
        ("检查二 · 小范围试跑", "文案先在单个页面看排版与阅读节奏；代码先在独立分支跑通、跑不通报错即作废，不并入主流程。", BLUE_T, BLUE),
        ("检查三 · 回归与一致性校验", "Dart 端侧与 Python 参考实现按 golden fixtures 逐值比对，31 个特征、10 组场景全过才算通过。", GREEN_T, GREEN),
        ("检查四 · 可解释与可维护", "每处改动都要能讲清依据；阈值不得写进代码，命名与注释齐全，便于后续维护与答辩说明。", ORANGE_T, ORANGE),
    ]

    y0, bh, gap = 40, 196, 52
    for i, (t, s, fill, border) in enumerate(steps):
        y = y0 + i * (bh + gap)
        block(d, 40, y, 2320, bh, fill, border, radius=22, width=3)
        cx, cy = 40 + 86, y + bh / 2
        d.ellipse([sc(cx - 40), sc(cy - 40), sc(cx + 40), sc(cy + 40)], fill=border)
        num = str(i + 1)
        tw = d.textlength(num, font=font(38, True)) / S
        d.text((sc(cx - tw / 2), sc(cy - 26)), num, font=font(38, True), fill="white")
        d.text((sc(190), sc(y + 26)), t, font=font(38, True), fill=border)
        lines = wrap(s, font(29), 1980, d)
        text_block(d, 190, y + 84, 2100, bh - 100, lines, font(29), INK, gap=1.5)
        if i < 3:
            arrow(d, 1200, y + bh + 6, 1200, y + bh + gap - 6, MUTED, width=4, head=16)

    fy = y0 + 4 * (bh + gap) + 4
    foot = "四道检查有一条不通过，该段 AI 输出即作废重做，不进入作品。"
    tw = d.textlength(foot, font=font(31)) / S
    d.text((sc((W - tw) / 2), sc(fy)), foot, font=font(31, True), fill=MUTED)

    save(img, "fig3-admission-gates.png")


if __name__ == "__main__":
    figure1()
    figure2()
    figure3()
