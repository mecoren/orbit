#!/usr/bin/env python3
"""Orbit 品牌图标生成器（M5.1；2026-09-07 换用户提供的卫星绕行图）。

用法（仓库根）：python scripts/generate_icons.py

产出（均覆盖写入）：
- 桌面 Tauri：apps/desktop/src-tauri/icons/{icon.png, icon.ico, icon.icns,
  32x32.png, 128x128.png, 128x128@2x.png, Square*.png, StoreLogo.png}
- 桌面关于页：apps/desktop/public/app-icon.png（256，透明底 squircle）
- Android 启动器：apps/mobile/android/app/src/main/res/mipmap-{m,hdpi,xhdpi,
  xxhdpi,xxxhdpi}/ic_launcher.png（Flutter 模板同尺寸族）
- Android 启动屏：mipmap-xxxhdpi/launch_image.png（512，无圆角全出血）
- Android 通知小图标：drawable-*/ic_stat_orbit.png（白色剪影，API 21+ 语义）
- 设计源文件：docs/adr/assets/orbit-icon-master.png

设计（源：scripts/PixPin_2026-09-07_20-16-46.png 经轮廓提取/简化/平滑）：
深色 squircle 底 + 卫星绕行星构图——左上月牙形行星、左下扫至右上的
变宽轨道弧（末端卫星球）、中部小彗星；主体蓝 #3974F7。形状数据固化在
scripts/icon_shapes.json（归一化 0..1 坐标 + 层级 z），参数改动请同步
更新本文件顶部注释与 0004 ADR。
"""

from __future__ import annotations

import json
import struct
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent
SHAPES_PATH = Path(__file__).resolve().parent / "icon_shapes.json"

# ---- 设计参数（与 docs/adr/0004 §图标一致）----
BG = (26, 26, 33, 255)  # squircle 底色（深空色 #1A1A21，与启动屏 launch_bg 同源）
BLUE = (57, 116, 247, 255)  # 主体蓝 #3974F7（源自用户图实测均值）
CORNER = 0.2237  # squircle 圆角率（Material，22.37%）
PAD = 0.10  # 主体内容边距（相对画布）

# Android 密度族：mipmap 名 -> 边长 px
ANDROID_DENSITIES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
# 通知小图标：密度族同上
NOTIFICATION_DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}


def load_shapes() -> list[dict]:
    """载入形状数据并归一化到 0..1（源 364×325 画布的内容 bbox）。"""
    shapes = json.loads(SHAPES_PATH.read_text())
    x0, y0, x1, y1 = 30, 23, 334, 294  # 源内容 bbox（提取时实测）
    for s in shapes:
        s["pts"] = [[(p[0] - x0) / (x1 - x0), (p[1] - y0) / (y1 - y0)] for p in s["pts"]]
    return shapes


SHAPES = load_shapes()
# 渲染顺序（z 从低到高）：轨道弧 -> 彗星 -> 卫星球 -> 月牙（行星压在弧尾根上）
ORDER = [0, 1, 2, 3]


def _draw_squircle(d: ImageDraw.ImageDraw, ss: int, radius_ratio: float = CORNER) -> None:
    if radius_ratio > 0:
        d.rounded_rectangle([0, 0, ss, ss], radius=int(ss * radius_ratio), fill=BG)
    else:
        d.rectangle([0, 0, ss, ss], fill=BG)


def render_master(size: int) -> Image.Image:
    """主图标：深色 squircle + 蓝主体（4x 超采样栅格化后 LANCZOS 缩到目标）。"""
    ss = 1024  # 固定超采样母版，保证任意尺寸一致性
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    _draw_squircle(d, ss)

    # 主体：PAD 边距内按归一化坐标铺形状
    m = ss * PAD
    span = ss - 2 * m
    # 垂直居中：源内容宽高比 305:272 ≈ 1.12，span 高度按比例缩减
    ar = 305 / 272
    span_y = span / ar
    my = (ss - span_y) / 2
    for i in ORDER:
        s = SHAPES[i]
        poly = [(m + px * span, my + py * span_y) for px, py in s["pts"]]
        d.polygon(poly, fill=BLUE)

    return im.resize((size, size), Image.LANCZOS)


def render_launch(size: int) -> Image.Image:
    """Android 启动屏图：无圆角全出血深色底（launch_background 平铺场景），主体同主图。"""
    ss = 1024
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    _draw_squircle(d, ss, radius_ratio=0)
    m = ss * PAD
    span = ss - 2 * m
    ar = 305 / 272
    span_y = span / ar
    my = (ss - span_y) / 2
    for i in ORDER:
        s = SHAPES[i]
        poly = [(m + px * span, my + py * span_y) for px, py in s["pts"]]
        d.polygon(poly, fill=BLUE)
    return im.resize((size, size), Image.LANCZOS)


def render_notification_silhouette(size: int) -> Image.Image:
    """通知小图标：纯白主体剪影（透明底），Android 5.0+ alpha 通道语义。"""
    ss = 512
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = ss * PAD
    span = ss - 2 * m
    ar = 305 / 272
    span_y = span / ar
    my = (ss - span_y) / 2
    for i in ORDER:
        s = SHAPES[i]
        poly = [(m + px * span, my + py * span_y) for px, py in s["pts"]]
        d.polygon(poly, fill=(255, 255, 255, 255))
    return im.resize((size, size), Image.LANCZOS)


def write_icns(images: list[Image.Image], path: Path) -> None:
    """手写 Apple ICNS 宯器（无需系统 iconutil，跨平台可复现）。"""
    entries = []
    for im in images:
        size = im.size[0]
        ostype = {
            16: b"icp4",
            32: b"icp5",
            64: b"icp6",
            128: b"ic07",
            256: b"ic08",
            512: b"ic09",
            1024: b"ic10",
        }[size]
        from io import BytesIO

        buf = BytesIO()
        im.save(buf, "PNG")
        data = buf.getvalue()
        entries.append(ostype + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(entries)
    with open(path, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)


def write_ico(sizes: list[int], path: Path) -> None:
    render_master(max(sizes)).save(
        path, format="ICO", sizes=[(s, s) for s in sizes]
    )


def self_check(master: Image.Image, notif: Image.Image) -> None:
    """生成后自检：深底存在、主体蓝覆盖、四角透明、通知图纯白。"""
    px = master.load()
    w, h = master.size
    # 1) 四角透明（squircle 圆角外）
    for x, y in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3)]:
        if px[x, y][3] > 40:
            raise RuntimeError(f"自检失败：圆角外不透明 ({x},{y})")
    # 2) 深底存在（采样远离主体带）
    for x, y in [(w // 2, int(h * 0.02)), (int(w * 0.02), h // 2)]:
        r, g, b, al = px[x, y]
        if abs(r - BG[0]) > 12 or abs(g - BG[1]) > 12 or abs(b - BG[2]) > 12 or al < 240:
            raise RuntimeError(f"自检失败：底色异常 ({x},{y}) -> ({r},{g},{b},{al})")
    # 3) 主体蓝存在（卫星球中心区域，归一化位置从形状数据推导）
    ball = min(SHAPES, key=lambda s: s["area"])  # 最小部件 = 卫星球
    bx = [p[0] for p in ball["pts"]]; by = [p[1] for p in ball["pts"]]
    cx, cy = sum(bx) / len(bx), sum(by) / len(by)
    m, span = 0.10, 0.80
    span_y = span / (305 / 272)
    my = (1 - span_y) / 2
    x, y = int((m + cx * span) * w), int((my + cy * span_y) * h)
    r, g, b, al = px[x, y]
    if abs(r - 57) > 25 or abs(g - 116) > 25 or abs(b - 247) > 25 or al < 240:
        raise RuntimeError(f"自检失败：卫星球中心非主体蓝 ({x},{y}) -> ({r},{g},{b},{al})")
    # 4) 通知小图标：只允许白色与透明
    npx = notif.load()
    for x in range(0, notif.size[0], 2):
        for y in range(0, notif.size[1], 2):
            r, g, b, al = npx[x, y]
            if al > 0 and (r, g, b) != (255, 255, 255):
                raise RuntimeError(f"自检失败：通知小图标含非白色像素 {r},{g},{b}")


def main() -> None:
    # ---- 母版与设计源 ----
    master = render_master(1024)
    master.save(REPO / "docs/adr/assets/orbit-icon-master.png")

    # ---- 桌面 Tauri 图标族 ----
    icons = REPO / "apps/desktop/src-tauri/icons"
    for size in (32, 64, 128, 512):
        render_master(size).save(icons / f"{size}x{size}.png")
    render_master(256).save(icons / "128x128@2x.png")
    # Windows Store 族（Tauri 官方清单；NSIS/MSI 打包引用）
    for size in (
        30, 44, 71, 89, 107, 142, 150, 284, 310,
    ):
        render_master(size).save(icons / f"Square{size}x{size}Logo.png")
    render_master(50).save(icons / "StoreLogo.png")
    write_ico([16, 24, 32, 48, 64, 128, 256], icons / "icon.ico")
    write_icns(
        [render_master(s) for s in (16, 32, 64, 128, 256, 512, 1024)],
        icons / "icon.icns",
    )
    render_master(512).save(icons / "icon.png")

    # ---- 桌面关于页 app-icon（透明底 squircle 同主图）----
    render_master(256).save(REPO / "apps/desktop/public/app-icon.png")

    # ---- Android 启动器图标 ----
    res = REPO / "apps/mobile/android/app/src/main/res"
    for bucket, size in ANDROID_DENSITIES.items():
        render_master(size).save(res / bucket / "ic_launcher.png")

    # ---- Android 启动屏（全出血无圆角，xxxhdpi 512 一枚）----
    render_launch(512).save(res / "mipmap-xxxhdpi/launch_image.png")

    # ---- Android 通知小图标 ----
    notif = render_notification_silhouette(512)
    for bucket, size in NOTIFICATION_DENSITIES.items():
        target = res / bucket / "ic_stat_orbit.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        render_notification_silhouette(size).save(target)

    # ---- 自检 ----
    self_check(render_master(512), notif)
    print("图标族生成完毕（含自检通过）")


if __name__ == "__main__":
    main()
