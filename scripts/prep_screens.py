# -*- coding: utf-8 -*-
"""整理材料用的真实截图：统一转 RGB、限制宽度、按用途命名。"""
import os
import shutil
from pathlib import Path

from PIL import Image

OUT = Path(r"D:\Code\VitalTeen\materials\screens")
OUT.mkdir(parents=True, exist_ok=True)

SRC = {
    "s1_welcome.png": r"D:\Code\VitalTeen\build\shotcheck\f_welcome.png",
    "s2_practice.png": r"D:\Code\VitalTeen-promo\assets\video\practice35.png",
    "s3_report.png": r"D:\Code\VitalTeen-promo\public\screens\report.png",
    "s4_posture.png": r"D:\Code\VitalTeen-promo\public\screens\posture_video.png",
    "s5_history.png": r"D:\Code\VitalTeen-promo\public\screens\report-b2.png",
}

for name, src in SRC.items():
    im = Image.open(src)
    if im.mode in ("RGBA", "P"):
        bg = Image.new("RGB", im.size, (255, 255, 255))
        im = im.convert("RGBA")
        bg.paste(im, mask=im.split()[-1])
        im = bg
    else:
        im = im.convert("RGB")
    if im.width > 1400:
        im = im.resize((1400, round(im.height * 1400 / im.width)), Image.LANCZOS)
    dst = OUT / name
    im.save(dst, "PNG", optimize=True)
    print(f"{name:18} <- {os.path.basename(src):22} {im.size} {dst.stat().st_size/1024:.0f} KB")
