# -*- coding: utf-8 -*-
"""生成参赛补充材料用的示意图（复用 make_ai_figures 的绘图原语）。"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import make_ai_figures as F
from make_ai_figures import (BLUE, BLUE_T, GREY_BORDER, GREY_FILL, GREEN, GREEN_T,
                             INK, MUTED, ORANGE, ORANGE_T, SKY, SKY_T, arrow, block,
                             check_layout, font, new_canvas, sc, text_block, wrap)

F.OUT_DIR = r"D:\Code\VitalTeen\materials\figures"


def canvas(w, h):
    return new_canvas(w, h)


# ---------------------------------------------------------------- 系统结构
def fig_system():
    W, H = 2400, 1560
    img, d = canvas(W, H)

    # 端侧
    block(d, 40, 60, 1120, 700, GREEN_T, GREEN, radius=26, width=3)
    d.text((sc(72), sc(82)), "端侧 · Android App（Flutter）", font=font(36, True), fill=GREEN)
    items = [
        ("相机与姿态推理", "ML Kit 33 关键点，逐帧推理"),
        ("领域层（Dart 移植）", "滤波 · 31 个特征 · 状态机 · 错误规则"),
        ("本机判定与报告", "断网可用；组末生成统计与参考分"),
        ("成长与历史", "打卡、等级、成就，仅存本机"),
    ]
    for i, (t, s) in enumerate(items):
        y = 150 + i * 148
        block(d, 76, y, 1048, 124, (255, 255, 255), GREEN, radius=16, width=2)
        text_block(d, 100, y + 14, 1000, 100,
                   [t] + wrap(s, font(27), 1000, d), font(27), INK, gap=1.45)

    # 服务端
    block(d, 1240, 60, 1120, 700, BLUE_T, BLUE, radius=26, width=3)
    d.text((sc(1272), sc(82)), "决策服务 · Flask + Laya", font=font(36, True), fill=BLUE)
    items2 = [
        ("决策契约", "请求/响应 schema 校验，版本可追溯"),
        ("候选集与方案库", "4—6 类错误、5—10 条方案，顺序随机化"),
        ("文案模板", "参数化话术，面向青少年可读"),
        ("降级与弃权", "置信不足时弃权，不编造结论"),
    ]
    for i, (t, s) in enumerate(items2):
        y = 150 + i * 148
        block(d, 1276, y, 1048, 124, (255, 255, 255), BLUE, radius=16, width=2)
        text_block(d, 1300, y + 14, 1000, 100, [t] + wrap(s, font(27), 1000, d), font(27), INK, gap=1.45)

    # 双向箭头
    arrow(d, 1172, 300, 1228, 300, SKY, width=5, head=16)
    arrow(d, 1228, 470, 1172, 470, SKY, width=5, head=16)
    d.text((sc(1146), sc(240)), "特征 JSON", font=font(25, True), fill=SKY)
    d.text((sc(1146), sc(500)), "判定 + 文案", font=font(25, True), fill=SKY)

    # 大屏
    block(d, 40, 820, 1580, 620, ORANGE_T, ORANGE, radius=26, width=3)
    d.text((sc(72), sc(842)), "数据可视化大屏 · Vue 3 + ECharts", font=font(36, True), fill=ORANGE)
    views = ["数据契约校验", "五个视图 · 点击下钻", "地图省名归一化", "离线静态部署"]
    for i, v in enumerate(views):
        x = 76 + (i % 2) * 760
        y = 916 + (i // 2) * 150
        block(d, x, y, 720, 120, (255, 255, 255), ORANGE, radius=16, width=2)
        text_block(d, x + 24, y + 28, 672, 70, [v], font(27), INK)

    # 数据源
    block(d, 1680, 820, 680, 620, GREY_FILL, GREY_BORDER, radius=26, width=3)
    d.text((sc(1712), sc(842)), "外部数据源", font=font(34, True), fill=MUTED)
    src = ["宏观统计数据集", "（需填写出处与许可）", "中国地图边界文件", "（需核实审图号）"]
    text_block(d, 1712, 910, 620, 480, [
        "· 宏观统计数据集", "   provenance 六项必填，缺一即拒绝加载", "",
        "· 地图边界 geojson", "   对外使用前须核实来源与审图号",
    ], font(26), INK, gap=1.7, valign="top")
    arrow(d, 1672, 1130, 1628, 1130, MUTED, width=4, head=14)

    # 隐私提示
    d.text((sc(40), sc(1470)),
           "隐私边界：视频帧不离开设备；上行的只有结构化特征与质量指标。",
           font=font(28, True), fill=SKY)

    check_layout()
    F.save(img, "fig_system-architecture.png")


# ---------------------------------------------------------------- 功能地图
def fig_features():
    W, H = 2400, 1420
    img, d = canvas(W, H)

    # 左：底栏四页
    d.text((sc(40), sc(20)), "四个一级页面", font=font(32, True), fill=MUTED)
    tabs = [("开始运动", "九个动作清单 + 今日打卡"), ("历史记录", "每组明细与状态"),
            ("体态", "倾向分析与处方"), ("我的", "档案、等级、设置")]
    for i, (t, s) in enumerate(tabs):
        y = 70 + i * 190
        block(d, 40, y, 620, 160, BLUE_T, BLUE, radius=18, width=3)
        text_block(d, 66, y + 20, 570, 120, [t] + wrap(s, font(25), 560, d), font(27), INK, gap=1.5)

    # 中：9 个动作
    d.text((sc(720), sc(20)), "九个动作 · 均已接入判定", font=font(32, True), fill=MUTED)
    acts = ["深蹲", "立定跳远", "开合跳", "俯卧撑", "仰卧起坐",
            "跳绳", "引体向上", "平板支撑", "坐位体前屈"]
    for i, a in enumerate(acts):
        x = 720 + (i % 3) * 330
        y = 70 + (i // 3) * 190
        block(d, x, y, 300, 160, GREEN_T, GREEN, radius=18, width=3)
        text_block(d, x + 20, y + 50, 260, 60, [a], font(29, True), INK, align="center")
        if i in (1, 5, 8, 3, 7):
            d.text((sc(x + 214), sc(y + 118)), "横屏", font=font(20, True), fill=ORANGE)

    # 右：报告与体态
    d.text((sc(1780), sc(20)), "组末报告与体态分析", font=font(32, True), fill=MUTED)
    block(d, 1780, 70, 580, 560, ORANGE_T, ORANGE, radius=18, width=3)
    text_block(d, 1806, 96, 528, 500, [
        "组末报告", "· 重复次数与有效次数", "· 错误分布与严重度",
        "· 参考分与分档", "· 矫正方案（剂量待核定）", "· 一句可读的提示",
    ], font(26), INK, gap=1.65, valign="top")

    block(d, 1780, 670, 580, 500, SKY_T, SKY, radius=18, width=3)
    text_block(d, 1806, 696, 528, 440, [
        "体态倾向", "· 近 30 天跨组聚合", "· 左右用力不均等倾向识别",
        "· 对应处方动作", "· 数据不足时只显示门槛提示",
    ], font(26), INK, gap=1.65, valign="top")

    check_layout()
    F.save(img, "fig_feature-map.png")


# ---------------------------------------------------------------- 使用流程
def fig_usage():
    W, H = 2400, 760
    img, d = canvas(W, H)
    steps = [
        ("安装", "下载 APK，\n允许未知来源"),
        ("授权", "首次进入授予\n相机权限"),
        ("选动作", "首页九项清单，\n含横屏提示"),
        ("对准取景", "人体占画面\n55%—90%"),
        ("跟随完成一组", "语音提示 + 实时骨架\n+ 次数计数"),
        ("组末报告", "错误、参考分、\n矫正方案"),
    ]
    bw, gap = 340, 60
    x0 = 40
    for i, (t, s) in enumerate(steps):
        x = x0 + i * (bw + gap)
        block(d, x, 120, bw, 400, SKY_T if i < 4 else GREEN_T,
              SKY if i < 4 else GREEN, radius=20, width=3)
        cx = x + bw / 2
        d.ellipse([sc(cx - 34), sc(150), sc(cx + 34), sc(218)], fill=SKY if i < 4 else GREEN)
        num = str(i + 1)
        tw = d.textlength(num, font=font(30, True)) / 2 / 2
        d.text((sc(cx - tw), sc(164)), num, font=font(30, True), fill="white")
        text_block(d, x + 24, 240, bw - 48, 260,
                   [t] + [ln for ln in s.split("\n")], font(26), INK, gap=1.55)
        if i < 5:
            arrow(d, x + bw + 6, 320, x + bw + gap - 6, 320, MUTED, width=4, head=14)

    d.text((sc(40), sc(560)), "全过程在手机本地完成：视频帧不出设备，断网也能出报告；练习记录只写本机。",
           font=font(27, True), fill=MUTED)
    d.text((sc(40), sc(620)), "组末报告里的矫正方案「剂量」一栏，在体育阈值核定前只给动作、不给组次数字。",
           font=font(27), fill=MUTED)

    check_layout()
    F.save(img, "fig_usage-flow.png")


# ---------------------------------------------------------------- 测试结果
def fig_tests():
    W, H = 2400, 900
    img, d = canvas(W, H)
    rows = [("领域层（Python）", 389, "特征、状态机、规则、阈值治理"),
            ("决策服务", 291, "契约、方案库、文案、降级"),
            ("校准评测（ml）", 43, "温度拟合与 ECE"),
            ("手机端（Flutter）", 0, "74 个测试文件；见说明")]
    maxv = 400
    top, rowh = 90, 170
    for i, (name, val, note) in enumerate(rows):
        y = top + i * rowh
        d.text((sc(40), sc(y + 16)), name, font=font(30, True), fill=INK)
        bar_x, bar_w = 640, 1180
        block(d, bar_x, y + 10, bar_w, 62, (243, 244, 246), (243, 244, 246), radius=12, width=1)
        if val:
            w = bar_w * val / maxv
            block(d, bar_x, y + 10, w, 62, GREEN if i < 3 else ORANGE,
                  GREEN if i < 3 else ORANGE, radius=12, width=1)
            d.text((sc(bar_x + w + 20), sc(y + 18)), f"{val} 项通过 · 0 失败",
                   font=font(28, True), fill=GREEN)
        else:
            d.text((sc(bar_x + 20), sc(y + 18)), "由端侧成员在开发机执行（本轮未跑）",
                   font=font(26), fill=MUTED)
        d.text((sc(40), sc(y + 78)), note, font=font(24), fill=MUTED)

    d.text((sc(40), sc(800)), "合计 723 项自动测试通过；测试在可写副本中执行，命令与输出随第 05 项材料留存。",
           font=font(26, True), fill=MUTED)

    check_layout()
    F.save(img, "fig_test-results.png")


# ---------------------------------------------------------------- 分工矩阵
def fig_team():
    W, H = 2400, 1180
    img, d = canvas(W, H)
    cols = ["领域层与算法", "端侧 App", "决策服务", "数据大屏", "内容与视觉", "材料与合规"]
    rows = ["成员 A", "成员 B", "成员 C", "成员 D", "成员 E"]
    owner = {("A", 0): 2, ("B", 1): 2, ("C", 2): 2, ("D", 3): 2, ("E", 4): 2}
    assist = {("A", 1): 1, ("A", 2): 1, ("B", 0): 1, ("B", 4): 1, ("C", 0): 1,
              ("C", 3): 1, ("D", 3): 0, ("D", 1): 0, ("E", 5): 2, ("E", 4): 0,
              ("B", 5): 1, ("C", 5): 1}

    x0, y0 = 300, 150
    cw, ch = 340, 130
    for j, c in enumerate(cols):
        d.text((sc(x0 + j * cw + 10), sc(y0 - 60)), c, font=font(25, True), fill=MUTED)
    for i, r in enumerate(rows):
        d.text((sc(40), sc(y0 + i * ch + 40)), r, font=font(30, True), fill=INK)

    for i, r in enumerate(rows):
        for j in range(len(cols)):
            key = (r[-1], j)
            cx, cy = x0 + j * cw + cw / 2, y0 + i * ch + ch / 2
            if owner.get(key) == 2:
                d.ellipse([sc(cx - 34), sc(cy - 34), sc(cx + 34), sc(cy + 34)], fill=BLUE)
                d.text((sc(cx - 12), sc(cy - 20)), "主", font=font(26, True), fill="white")
            elif key in assist:
                d.ellipse([sc(cx - 22), sc(cy - 22), sc(cx + 22), sc(cy + 22)],
                          outline=SKY, width=sc(4))
            else:
                d.ellipse([sc(cx - 6), sc(cy - 6), sc(cx + 6), sc(cy + 6)], fill=GREY_BORDER)

    # 图例
    ly = 940
    d.ellipse([sc(60), sc(ly), sc(120), sc(ly + 60)], fill=BLUE)
    d.text((sc(80), sc(ly + 12)), "主", font=font(24, True), fill="white")
    d.text((sc(140), sc(ly + 12)), "主责", font=font(26), fill=MUTED)
    d.ellipse([sc(300), sc(ly + 8), sc(340), sc(ly + 48)], outline=SKY, width=sc(4))
    d.text((sc(360), sc(ly + 12)), "参与", font=font(26), fill=MUTED)
    d.ellipse([sc(480), sc(ly + 18), sc(492), sc(ly + 30)], fill=GREY_BORDER)
    d.text((sc(510), sc(ly + 12)), "不参与", font=font(26), fill=MUTED)

    d.text((sc(40), sc(1040)), "分工按实际开发记录整理；评审材料中不出现姓名、学校与指导教师信息。",
           font=font(26), fill=MUTED)

    check_layout()
    F.save(img, "fig_team-division.png")


def fig_resources():
    W, H = 2400, 1280
    img, d = canvas(W, H)

    groups = [
        ("代码库与框架（开源）", BLUE, BLUE_T, [
            ("Flutter / Dart SDK", "BSD-3-Clause"),
            ("Vue 3 / Vite", "MIT"),
            ("ECharts", "Apache-2.0"),
            ("Flask", "BSD-3-Clause"),
            ("NumPy / pandas", "BSD-3-Clause"),
            ("Vitest / Remotion", "MIT / Remotion License"),
        ]),
        ("模型与数据", GREEN, GREEN_T, [
            ("Laya 轻量决策模型", "按其仓库声明"),
            ("公开动作数据集", "PDDL 等，仅评测"),
            ("宏观统计数据集", "未接入，待核实"),
            ("地图边界 geojson", "待核实审图号"),
            ("—", "—"),
            ("—", "—"),
        ]),
        ("素材与服务", ORANGE, ORANGE_T, [
            ("演示配乐与音效", "Mixkit Free License"),
            ("品牌图形", "团队自制"),
            ("界面截图", "本机实拍"),
            ("示意图（本材料）", "团队自绘"),
            ("系统字体", "随系统，不随包分发"),
            ("—", "—"),
        ]),
    ]

    col_w, gap = 740, 40
    for gi, (title, color, tint, items) in enumerate(groups):
        x = 40 + gi * (col_w + gap)
        block(d, x, 40, col_w, 1160, tint, color, radius=24, width=3)
        d.text((sc(x + 28), sc(64)), title, font=font(31, True), fill=color)
        for ii, (name, lic) in enumerate(items):
            if name == "—":
                continue
            y = 132 + ii * 168
            block(d, x + 24, y, col_w - 48, 144, (255, 255, 255), color, radius=14, width=2)
            text_block(d, x + 44, y + 16, col_w - 88, 110,
                       wrap(name, font(26), col_w - 88, d) + ["许可：" + lic],
                       font(26), INK, gap=1.5, valign="middle")

    d.text((sc(40), sc(1216)),
           "开源依赖的版本与许可证以各仓库随附 LICENSE 为准；商业素材均在授权范围内使用，逐条来源见正文表格。",
           font=font(25), fill=MUTED)

    check_layout()
    F.save(img, "fig_resources.png")


if __name__ == "__main__":
    os.makedirs(F.OUT_DIR, exist_ok=True)
    fig_system()
    fig_features()
    fig_usage()
    fig_tests()
    fig_team()
    fig_resources()
