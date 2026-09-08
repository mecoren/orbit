#!/usr/bin/env python3
"""Orbit 品牌图标生成器（M5.1；2026-09-08 换 AI 生图「圆环轨道」版）。

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

设计 v4.1（源：scripts/icon-asset-2026-09-08.png，AI 生图已带透明通道）：
蓝色正圆环（缺口嵌卫星球、彗星从中心越环）+ 双层 glow 光晕；主体蓝
#2B6EF7。资产为栅格合成（环圆度实测 ±2px、蓝色 std<3，无需重描）；
**全族透明底**（用户口径「扣成透明背景」）——无底板，深色底由宿主环境
提供；Android 启动屏的深色由 launch_background.xml 的 launch_bg 提供。
内容对齐：solid bbox 占画布 80%，glow 越出 PAD 自然淡出。参数改动请
同步更新本文件顶部注释与 0004 ADR。
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent
ASSET_PATH = Path(__file__).resolve().parent / "icon-asset-2026-09-08.png"

# ---- 设计参数（与 docs/adr/0004 §图标一致）----
PAD = 0.10  # solid 主体边距（相对画布；glow 越出边距自然淡出）
# 资产内 solid 内容 bbox（icon-asset-2026-09-08.png 941×961 实测）
SOLID_BBOX = (43, 100, 864, 830)  # x0, y0, x1, y1（含端点）

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

ASSET = Image.open(ASSET_PATH).convert("RGBA")


def _place_asset(im: Image.Image, ss: int) -> None:
    """资产 solid bbox 按 PAD 对齐缩放贴入 ss×ss 画布（glow 可越出）。"""
    sx0, sy0, sx1, sy1 = SOLID_BBOX
    content_w = sx1 - sx0 + 1
    content_h = sy1 - sy0 + 1
    scale = (ss - 2 * ss * PAD) / content_w
    dw = round(ASSET.width * scale)
    dh = round(ASSET.height * scale)
    resized = ASSET.resize((dw, dh), Image.LANCZOS)
    # solid bbox 中心对画布中心
    cx_a = (sx0 + sx1) / 2 * scale
    cy_a = (sy0 + sy1) / 2 * scale
    x = round(ss / 2 - cx_a)
    y = round(ss / 2 - cy_a)
    im.alpha_composite(resized, (x, y))


def _solid_silhouette(size: int) -> Image.Image:
    """资产不透明主体（alpha>128）二值剪影，白色，供通知图/自检。"""
    ss = 512
    m = Image.new("L", ss, 0)
    a = ASSET.resize((ss, ss), Image.LANCZOS)
    px = a.load()
    d = ImageDraw.Draw(m)
    for y in range(ss):
        for x in range(ss):
            if px[x, y][3] > 128:
                d.point((x, y), fill=255)
    white = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    white.putalpha(m)
    return Image.merge("RGBA", (m, m, m, white.split()[3])).resize(
        (size, size), Image.LANCZOS)


def render_master(size: int) -> Image.Image:
    """主图标：透明底 + 资产直放（固定 1024 母版缩放）。

    用户口径「扣成透明背景」——无任何底色/底板，图标即资产本身；
    深色底由各宿主环境提供（桌面任务栏/Android 桌面/关于页背景）。
    """
    ss = 1024
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    _place_asset(im, ss)
    return im.resize((size, size), Image.LANCZOS)


def render_launch(size: int) -> Image.Image:
    """Android 启动屏图：透明底（launch_background.xml 的 launch_bg 提供深色）。"""
    return render_master(size)


def render_notification_silhouette(size: int) -> Image.Image:
    """通知小图标：主体白色剪影（透明底），Android 5.0+ alpha 通道语义。

    以 solid 层的外接紧框（非含 glow 的全资产框）铺放，保证小尺寸主体占比。
    """
    ss = 512
    sx0, sy0, sx1, sy1 = SOLID_BBOX
    scale = (ss - 2 * ss * PAD) / (sx1 - sx0 + 1)
    dw = round(ASSET.width * scale)
    dh = round(ASSET.height * scale)
    resized = ASSET.resize((dw, dh), Image.LANCZOS)
    cx_a = (sx0 + sx1) / 2 * scale
    cy_a = (sy0 + sy1) / 2 * scale
    x = round(ss / 2 - cx_a)
    y = round(ss / 2 - cy_a)
    canvas = Image.new("L", (ss, ss), 0)
    canvas.paste(resized.split()[3].point(lambda v: 255 if v > 128 else 0), (x, y))
    white = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    px = canvas.load()
    d = ImageDraw.Draw(white)
    for yy in range(ss):
        for xx in range(ss):
            if px[xx, yy] > 0:
                d.point((xx, yy), fill=(255, 255, 255, 255))
    return white.resize((size, size), Image.LANCZOS)


def write_icns(images: list[Image.Image], path: Path) -> None:
    """手写 Apple ICNS 容器（无需系统 iconutil，跨平台可复现）。"""
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
    """生成后自检：底透明、主体蓝覆盖、通知图纯白。"""
    px = master.load()
    w, h = master.size
    # 1) 底透明（四角 + 上下左右边缘中点，均应无背景板）
    for x, y in [(2, 2), (w - 3, 2), (2, h - 3), (w - 3, h - 3),
                 (w // 2, 2), (w // 2, h - 3), (2, h // 2), (w - 3, h // 2)]:
        r, g, b, al = px[x, y]
        if al > 30:
            raise RuntimeError(f"自检失败：底不透明 ({x},{y}) -> ({r},{g},{b},{al})")
    # 3) 主体蓝存在（环带实测绘于 512 图：r≈143..210，取中带 r=0.34w）
    cx = cy = w / 2
    rr = w * 0.34  # 环带中段（512 图实测 solid 峰区 143..251）
    hits = 0
    import math
    for deg in range(0, 360, 30):
        x = int(cx + rr * math.cos(math.radians(deg)))
        y = int(cy + rr * math.sin(math.radians(deg)))
        if 0 <= x < w and 0 <= y < h:
            r, g, b, al = px[x, y]
            if al > 200 and b - r > 60:
                hits += 1
    if hits < 6:
        raise RuntimeError(f"自检失败：环带蓝色采样命中不足（{hits}/12）")
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
