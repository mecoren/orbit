#!/usr/bin/env python3
"""Orbit 品牌图标生成器（M5.1）。

用法（仓库根）：python scripts/generate_icons.py

产出（均覆盖写入）：
- 桌面 Tauri：apps/desktop/src-tauri/icons/{icon.png, icon.ico, icon.icns,
  32x32.png, 128x128.png, 128x128@2x.png, Square*.png, StoreLogo.png}
- Android 启动器：apps/mobile/android/app/src/main/res/mipmap-{m,hdpi,xhdpi,
  xxhdpi,xxxhdpi}/ic_launcher.png（Flutter 模板同尺寸族）
- Android 通知小图标：drawable-*/ic_stat_orbit.png（白色剪影，API 21+ 语义）
- 设计源文件：docs/adr/assets/orbit-icon-master.png

设计：深色 squircle 底 + 蓝青渐变椭圆轨道 + 白色中心点与卫星点（呼应
「循迹」产品语义与桌面 accent #4E8CFF）。参数改动请同步更新本文件顶部
注释与 0004 ADR。
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent

# ---- 设计参数（与 docs/adr/0004 §图标一致）----
BG = (23, 26, 33, 255)  # squircle 底色（深空色）
BLUE = (78, 140, 255)  # 桌面 accent #4E8CFF
CYAN = (94, 219, 231)  # 轨道高光端
ROT = math.radians(-24)  # 轨道逆时针倾角
RING_W = 0.088  # 轨道环宽（相对画布）
ELLIPSE = (0.30, 0.385)  # 轨道 rx/ry（相对画布）
CENTER = (0.5, 0.52)  # 轨道中心

# Android 密度族：mipmap 名 -> 边长 px
ANDROID_DENSITIES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}
# 通知小图标：纯白剪影（API 21+ 系统按需着色），密度族同上
NOTIFICATION_DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}


def _lerp(a: tuple, b: tuple, t: float) -> tuple:
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def render_master(size: int) -> Image.Image:
    """渲染主图标（透明画布 + 深色 squircle + 轨道）。"""
    ss = 1024  # 固定超采样母版，保证任意尺寸一致性
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # squircle 近似：Material 圆角率 22.37%
    d.rounded_rectangle([0, 0, ss, ss], radius=int(ss * 0.2237), fill=BG)

    cx, cy = ss * CENTER[0], ss * CENTER[1]
    rx, ry = ss * ELLIPSE[0], ss * ELLIPSE[1]
    rr = ss * RING_W / 2

    # 渐变轨道：密集圆点沿参数轨迹铺满成环
    steps = 720
    for i in range(steps):
        ang = (i / steps) * 2 * math.pi - math.pi / 2
        ex, ey = rx * math.cos(ang), ry * math.sin(ang)
        x = cx + ex * math.cos(ROT) - ey * math.sin(ROT)
        y = cy + ex * math.sin(ROT) + ey * math.cos(ROT)
        col = _lerp(BLUE, CYAN, (math.sin(ang) + 1) / 2)
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=(*col, 255))

    def orbit_point(angle: float) -> tuple[float, float]:
        ex, ey = rx * math.cos(angle), ry * math.sin(angle)
        return (
            cx + ex * math.cos(ROT) - ey * math.sin(ROT),
            cy + ex * math.sin(ROT) + ey * math.cos(ROT),
        )

    # 中心白点（轨道顶点的"本体"）
    vx, vy = orbit_point(-math.pi / 2)
    pr = ss * 0.072
    d.ellipse([vx - pr, vy - pr, vx + pr, vy + pr], fill=(255, 255, 255, 255))

    # 前景卫星点（36° 处，呼应"循迹"运动方向）
    sx, sy = orbit_point(math.radians(36))
    sr = ss * 0.052
    d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 255, 255, 255))

    return im.resize((size, size), Image.LANCZOS)


def render_notification_silhouette(size: int) -> Image.Image:
    """通知小图标：纯白轨道剪影（透明底），Android 5.0+ alpha 通道语义。"""
    ss = 512
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # 轨道环：白色粗描边椭圆（未闭合——留缺口形成"轨迹"感并避免闭环歧义）
    cx, cy = ss * CENTER[0], ss * CENTER[1]
    rx, ry = ss * (ELLIPSE[0] * 1.28), ss * (ELLIPSE[1] * 1.28)
    rr = ss * RING_W / 2
    steps = 720
    gap = math.radians(50)  # 缺口角宽
    gap_center = math.radians(36)  # 缺口中心（卫星点位置对侧）
    for i in range(steps):
        ang = (i / steps) * 2 * math.pi
        # 跳过缺口段
        delta = (ang - gap_center) % (2 * math.pi)
        if delta < gap / 2 or delta > 2 * math.pi - gap / 2:
            continue
        ex, ey = rx * math.cos(ang), ry * math.sin(ang)
        x = cx + ex * math.cos(ROT) - ey * math.sin(ROT)
        y = cy + ex * math.sin(ROT) + ey * math.cos(ROT)
        d.ellipse([x - rr, y - rr, x + rr, y + rr], fill=(255, 255, 255, 255))

    # 中心点（白色实心）
    pr = ss * 0.10
    d.ellipse([cx - pr, cy - pr, cx + pr, cy + pr], fill=(255, 255, 255, 255))

    # 卫星点（缺口内，呼应主图 36° 卫星）
    ex, ey = rx * math.cos(gap_center), ry * math.sin(gap_center)
    sx = cx + ex * math.cos(ROT) - ey * math.sin(ROT)
    sy = cy + ex * math.sin(ROT) + ey * math.cos(ROT)
    sr = ss * 0.075
    d.ellipse([sx - sr, sy - sr, sx + sr, sy + sr], fill=(255, 255, 255, 255))

    return im.resize((size, size), Image.LANCZOS)


def write_icns(images: list[Image.Image], path: Path) -> None:
    """手写 Apple ICNS 容器（无需系统 iconutil，跨平台可复现）。"""
    # icon 类型：尺寸 -> (osType, 像素格式 ic04=ARGB 无压缩 PNG 也允许；用 PNG 编码段)
    # ICOS 容器规范：magic 'icns' + 总长；各条目 osType + 长度 + PNG 数据
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
    """生成后自检：轨道环闭合、渐变两端色、白色卫星点、通知图纯白。"""
    px = master.load()
    w, h = master.size
    cx, cy = w * CENTER[0], h * CENTER[1]
    rx, ry = w * ELLIPSE[0], h * ELLIPSE[1]
    has_blue = has_cyan = False
    for deg in range(0, 360, 2):
        a = math.radians(deg - 90)
        ex, ey = rx * math.cos(a), ry * math.sin(a)
        x = int(cx + ex * math.cos(ROT) - ey * math.sin(ROT))
        y = int(cy + ex * math.sin(ROT) + ey * math.cos(ROT))
        if 0 <= x < w and 0 <= y < h:
            r, g, b, al = px[x, y]
            if al > 200:
                if b > 200 and r < 120:
                    has_blue = True
                if g > 180 and b > 180:
                    has_cyan = True
    if not (has_blue and has_cyan):
        raise RuntimeError("自检失败：轨道渐变两端色未同时出现")

    # 卫星白点
    a = math.radians(-90)
    ex, ey = rx * math.cos(a), ry * math.sin(a)
    vx = int(cx + ex * math.cos(ROT) - ey * math.sin(ROT))
    vy = int(cy + ex * math.sin(ROT) + ey * math.cos(ROT))
    white = any(
        px[vx + dx, vy + dy][:3] == (255, 255, 255)
        for dx in (-2, 0, 2)
        for dy in (-2, 0, 2)
    )
    if not white:
        raise RuntimeError("自检失败：白色卫星点缺失")

    # 通知小图标：只允许白色与透明
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

    # ---- Android 启动器图标 ----
    res = REPO / "apps/mobile/android/app/src/main/res"
    for bucket, size in ANDROID_DENSITIES.items():
        render_master(size).save(res / bucket / "ic_launcher.png")

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
