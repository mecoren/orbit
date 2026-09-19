#!/usr/bin/env python3
"""Orbit 品牌图标生成器（M5.1；2026-09-08 换 AI 生图「圆环轨道」版）。

用法（仓库根）：python scripts/generate_icons.py

产出（均覆盖写入）：
- 桌面 Tauri：apps/desktop/src-tauri/icons/{icon.png, icon.ico, icon.icns,
  32x32.png, 128x128.png, 128x128@2x.png, Square*.png, StoreLogo.png}
- 桌面关于页：apps/desktop/public/app-icon.png（256，透明底 squircle）
- Android 启动器：apps/mobile/android/app/src/main/res/mipmap-{m,hdpi,xhdpi,
  xxhdpi,xxxhdpi}/ic_launcher.png（Flutter 模板同尺寸族）
- Android 自适应图标（API 26+）：mipmap-anydpi-v26/{ic_launcher,
  ic_launcher_round}.xml（白底 @color/ic_launcher_background + 前景分层）
  + mipmap-*/ic_launcher_foreground.png（108dp 画布，内容缩入安全区）
- Android 启动屏：mipmap-xxxhdpi/launch_image.png（512，无圆角全出血）
- 移动端 Flutter 资产：apps/mobile/assets/app_icon.png（512，启动等待
  画面白底居中显示，与桌面同源图标）
- Android 通知小图标：drawable-*/ic_stat_orbit.png（白色剪影，API 21+ 语义）
- 设计源文件：docs/adr/assets/orbit-icon-master.png

设计 v5（源：scripts/icon-asset-2026-09-08b.png，AI 生图带透明通道）：
蓝色正圆环（缺口嵌卫星球、彗星从中心越环）+ 双层 glow 光晕；主体蓝
#2B6EF7。资产为栅格合成（环圆度实测 ±2px、蓝色 std<3，无需重描）；
**全族透明底**（用户口径「扣成透明背景」）——无底板，深色底由宿主环境
提供；Android 启动屏为白底 + 居中本图（launch_background.xml 的 launch_bg）。

图标口径（2026-09-19）：移动端与桌面端**同一枚图标**——launcher 图标、
原生启动屏图、Flutter 等待画面资产三处全部出自本脚本的 render_master，
换版一次产出全平台，不允许单端手改位图。
内容对齐：**短轴定标**——以 solid 短轴（蓝色圆环外径 812，视觉主体）
撑满画布 86%（PAD=0.07），fit_scale 夹逼保证整幅资产不越界、彗星尾梢
不裁；源图已按 solid 紧框裁过（glow 余量≈0），环占 88.2% 为 clip-free
上限。参数改动请同步更新本文件顶部注释与 0004 ADR。
"""

from __future__ import annotations

import struct
from pathlib import Path

from PIL import Image, ImageDraw

REPO = Path(__file__).resolve().parent.parent
ASSET_PATH = Path(__file__).resolve().parent / "icon-asset-2026-09-08b.png"

# ---- 设计参数（与 docs/adr/0004 §图标一致）----
PAD = 0.07  # solid 短轴边距（相对画布；短轴=蓝色圆环外径，视觉主体定标基准）
# 资产内 solid 内容 bbox（icon-asset-2026-09-08b.png 920×816 实测）
SOLID_BBOX = (1, 3, 915, 814)  # x0, y0, x1, y1（含端点）


def fit_scale(ss: int, pad: float = PAD) -> float:
    """定标系数：以 solid 短轴（=蓝色圆环外径 812，视觉主体）撑满 (1-2*pad)*ss。

    夹逼 ss/ASSET.width 保证整幅资产不越出画布——彗星尾梢与 glow 一律不裁。
    """
    sx0, sy0, sx1, sy1 = SOLID_BBOX
    short_axis = min(sx1 - sx0 + 1, sy1 - sy0 + 1)
    return min((ss - 2 * ss * pad) / short_axis, ss / ASSET.width)


# Android 密度族：mipmap 名 -> 边长 px
# 说明（2026-09-19）：像素按 2 倍规格给（48dp 图标给 96px）——Android 按
# 目录 bucket 换算 dp 后自行缩放，给足像素只赚清晰度；启动器与 OEM 启动
# 画面（Android 12+ 系统 SplashScreen 把图标放大到 192dp 区域）会放大绘制，
# 1x 像素会被放大糊化，这是用户反馈「图标发虚」的直接原因。
ANDROID_DENSITIES = {
    "mipmap-mdpi": 96,
    "mipmap-hdpi": 144,
    "mipmap-xhdpi": 192,
    "mipmap-xxhdpi": 288,
    "mipmap-xxxhdpi": 384,
}
# 自适应图标（API 26+ 分层图标）：画布 108dp，前景层内容缩入安全区。
# 像素同样按 2 倍规格给（108dp 画布给 216px）：系统启动画面会把前景层
# 放大绘制（API 31+ 系统 SplashScreen 图标区 288dp、可见 192dp；
# OEM 启动动画另有放大），2x 像素保证放大后不糊。
ADAPTIVE_DENSITIES = {
    "mipmap-mdpi": 216,
    "mipmap-hdpi": 324,
    "mipmap-xhdpi": 432,
    "mipmap-xxhdpi": 648,
    "mipmap-xxxhdpi": 864,
}
# 108dp 画布中系统可见区 72dp（66.7%）；取 60%（pad 0.20）给彗星尾梢留
# 余量——圆形 / 圆角方形遮罩下四角不裁到品牌图形。
ADAPTIVE_PAD = 0.20

# 通知小图标：密度族同上
NOTIFICATION_DENSITIES = {
    "drawable-mdpi": 24,
    "drawable-hdpi": 36,
    "drawable-xhdpi": 48,
    "drawable-xxhdpi": 72,
    "drawable-xxxhdpi": 96,
}

ASSET = Image.open(ASSET_PATH).convert("RGBA")


def _place_asset(im: Image.Image, ss: int, pad: float = PAD) -> None:
    """资产按 fit_scale 短轴定标缩放贴入 ss×ss 画布（整幅资产不越界）。"""
    sx0, sy0, sx1, sy1 = SOLID_BBOX
    scale = fit_scale(ss, pad)
    dw = round(ASSET.width * scale)
    dh = round(ASSET.height * scale)
    resized = ASSET.resize((dw, dh), Image.LANCZOS)
    # solid bbox 中心对画布中心
    cx_a = (sx0 + sx1) / 2 * scale
    cy_a = (sy0 + sy1) / 2 * scale
    x = round(ss / 2 - cx_a)
    y = round(ss / 2 - cy_a)
    im.alpha_composite(resized, (x, y))


def _steepen_alpha(im: Image.Image, lo: float, hi: float) -> Image.Image:
    """alpha 通道 [lo,hi]→[0,255] 线性重映射（陡化），消除小尺寸下的抗锯齿灰雾。"""
    import numpy as np

    a = np.array(im)
    al = a[:, :, 3].astype(float)
    a[:, :, 3] = np.clip((al - lo) / (hi - lo) * 255, 0, 255).astype(np.uint8)
    return Image.fromarray(a)


# 小尺寸特调档（任务栏/标题栏显示区）：仅 alpha 陡化（去抗锯齿灰雾），
# 几何定标统一走短轴 PAD/fit_scale。动机：≤24px 下环带边缘中间调占比高，
# 显示发灰；陡化后边缘干净。实测（16px）蓝像素 55→58、不透明覆盖
# 21.5%→22.7%。若小图观感仍发虚优先抬 lo，不要再动几何。
SMALL_TIERS = {
    16: (160, 235),
    20: (160, 235),
    24: (150, 240),
    32: (140, 245),
}


def render_master(size: int) -> Image.Image:
    """主图标：透明底 + 资产直放（固定 1024 母版缩放，短轴定标）。

    用户口径「扣成透明背景」——无任何底色/底板，图标即资产本身；
    深色底由各宿主环境提供（桌面任务栏/Android 桌面/关于页背景）。
    ≤32px 额外走 SMALL_TIERS alpha 陡化（去灰雾），几何定标全族统一。
    """
    ss = 1024
    im = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    _place_asset(im, ss)
    if size in SMALL_TIERS:
        im = _steepen_alpha(im, *SMALL_TIERS[size])
    return im.resize((size, size), Image.LANCZOS)


def render_launch(size: int) -> Image.Image:
    """Android 启动屏图：透明底（白底由 launch_background.xml 的 launch_bg 提供）。"""
    return render_master(size)


def render_adaptive_foreground(size: int) -> Image.Image:
    """自适应图标前景层：透明底，品牌图形按 ADAPTIVE_PAD 缩入安全区。"""
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    _place_asset(im, size, ADAPTIVE_PAD)
    return im


def write_adaptive_icons(res: Path) -> None:
    """写自适应图标族：前景层密度族 + mipmap-anydpi-v26 分层描述。

    背景层取 `@color/ic_launcher_background`（**透明**，见
    res/values/colors.xml）——与桌面端口径一致：图标即透明底品牌图形，
    不铺白底/底板。缺分层时系统启动画面会给 legacy 位图自造一层模糊
    底板（观感发灰、图标被放大），这正是 2026-09-19 移动端「图标带
    模糊背景」的根因；铺白底则会出现白色圆角方块（同日二次反馈）。
    """
    for bucket, size in ADAPTIVE_DENSITIES.items():
        render_adaptive_foreground(size).save(
            res / bucket / "ic_launcher_foreground.png")
    anydpi = res / "mipmap-anydpi-v26"
    anydpi.mkdir(parents=True, exist_ok=True)
    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- Orbit 自适应图标（API 26+）：白底 + 品牌前景层；"
        "脚本产出（scripts/generate_icons.py），勿手改。 -->\n"
        '<adaptive-icon xmlns:android='
        '"http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    for name in ("ic_launcher.xml", "ic_launcher_round.xml"):
        (anydpi / name).write_text(xml, encoding="utf-8")


def render_notification_silhouette(size: int) -> Image.Image:
    """通知小图标：主体白色剪影（透明底），Android 5.0+ alpha 通道语义。

    几何与主图共用 fit_scale 口径（不逐处漂移）；状态栏图标有额外内缩
    惯例，取 pad=0.10（短轴口径下环占 80%，仍大于旧 width 口径的 71%），
    避免 24px 档彗星尾梢贴边被 OEM 切梢。
    """
    ss = 512
    canvas = Image.new("RGBA", (ss, ss), (0, 0, 0, 0))
    _place_asset(canvas, ss, 0.10)
    a = canvas.split()[3].point(lambda v: 255 if v > 128 else 0)
    white = Image.new("L", (ss, ss), 255)
    return Image.merge("RGBA", (white, white, white, a)).resize(
        (size, size), Image.LANCZOS)


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
    """手写多槽 ICO 容器（Pillow sizes 参数不支持 20px 等槽且为二次缩放）。

    槽位覆盖 Windows DPI 缩放取值：16/20/24/32/40/48/64/96/128/256
    （任务栏 96/125/150/200% 分别取 16-20/20-24/24-32/32-40）。
    每槽从 render_master 独立渲染（小尺寸走特调档），避免从 256 二次缩小。
    **槽位降序写入（256 首位）**：tauri-codegen 的 new_ico 取 entries()[0]
    作为 default_window_icon（窗口/托盘共用位图）——首帧必须是最大档，
    否则任务栏把 16px 位图拉伸到 24-32px 显示为糊（托盘 1:1 反而清晰，
    2026-09-09 用户报告「任务栏糊托盘清」的根因）。
    """
    from io import BytesIO

    entries = []
    imgs = []
    for s in sorted(sizes, reverse=True):
        im = render_master(s)
        buf = BytesIO()
        im.save(buf, "PNG")
        imgs.append((s, buf.getvalue()))

    # ICONDIR 头：reserved(2)=0, type(2)=1, count(2)
    n = len(imgs)
    header = struct.pack("<HHH", 0, 1, n)
    dir_entries = b""
    offset = 6 + 16 * n
    for s, data in imgs:
        w = 0 if s >= 256 else s
        dir_entries += struct.pack(
            "<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    with open(path, "wb") as f:
        f.write(header + dir_entries + b"".join(d for _, d in imgs))


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
    # 3) 主体蓝存在（短轴定标后实测采样平台：rr=0.325w 在 PAD 0.06~0.08
    # 区间均 12/12 命中；取平台中心而非边缘，抗后续微调）
    cx = cy = w / 2
    rr = w * 0.325  # 环带中段
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
    write_ico([16, 20, 24, 32, 40, 48, 64, 96, 128, 256], icons / "icon.ico")
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

    # ---- Android 自适应图标（API 26+ 分层：白底 + 品牌前景）----
    write_adaptive_icons(res)

    # ---- Android 启动屏（全出血无圆角，xxxhdpi 512 一枚）----
    render_launch(512).save(res / "mipmap-xxxhdpi/launch_image.png")

    # ---- 移动端 Flutter 资产（启动等待画面白底居中，与桌面同源图标）----
    mobile_assets = REPO / "apps/mobile/assets"
    mobile_assets.mkdir(parents=True, exist_ok=True)
    render_master(512).save(mobile_assets / "app_icon.png")

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
