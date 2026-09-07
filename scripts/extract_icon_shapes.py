#!/usr/bin/env python3
"""icon_shapes.json 重建（v3 终版）：高斯平滑重阈值去手绘波纹。

背景：v2 直接描摹手绘轮廓，轨道弧带入手绘波纹（用户反馈「下面的
不够圆，太乱了」）。骨架/中轴/圆拟合路线全部失败（宽带区细化产生
环状骨架、弧率处处变化非单一圆），最终采用**尺度分离**方案：
- 掩膜 2x 超采样 → 高斯模糊（σ=5，抹平周期 <10px 的笔触波纹）→
  127 重阈值 → 波纹消失、宏观形状（走向/宽度变化/收笔）完整保留，
  轨道弧 IoU 0.978
- 轮廓 → approxPolyDP 轻简化（1.5px 容差）→ Chaikin 平滑
- 卫星球: 质心 + 中位半径正 64 边形（原图即圆，直接理想化）

部件顺序（渲染 z 序）: 轨道弧 / 彗星 / 卫星球 / 行星。

输出 scripts/icon_shapes.json：{canvas, bbox, shapes}（像素坐标）。
"""
from __future__ import annotations

import json
import math

import cv2
import numpy as np
from PIL import Image

SRC = "scripts/PixPin_2026-09-07_20-16-46.png"
OUT = "scripts/icon_shapes.json"
SIGMA = 5  # 高斯平滑尺度（2x 采样空间；波纹周期 <10px 滤除）

im = Image.open(SRC).convert("RGB")
W, H = im.size
arr = np.array(im).astype(np.int16)
dist = 255 - np.minimum(np.minimum(arr[:, :, 0], arr[:, :, 1]), arr[:, :, 2])
mask = ((dist > 60) * 255).astype(np.uint8)
mask[:12, :12] = 0; mask[:12, -12:] = 0; mask[-12:, :12] = 0; mask[-12:, -12:] = 0
mask = cv2.morphologyEx(mask, cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))

nlab, labs, stats, cent = cv2.connectedComponentsWithStats(mask, 8)
by_bbox = lambda x, y: next(i for i in range(1, nlab)
                            if abs(stats[i, 0] - x) < 8 and abs(stats[i, 1] - y) < 8)
swoosh_id = next(i for i in range(1, nlab) if stats[i, 4] == max(stats[1:, 4]))
comet_id, ball_id, planet_id = by_bbox(135, 108), by_bbox(254, 49), by_bbox(49, 23)


def idealize(component_id: int) -> tuple[np.ndarray, float]:
    """高斯平滑重阈值去波纹 + 轻简化 + Chaikin；返回 (多边形, IoU)。"""
    src = labs == component_id
    m2 = cv2.resize(src.astype(np.uint8) * 255, (W * 2, H * 2),
                    interpolation=cv2.INTER_NEAREST)
    k = int(SIGMA * 3) | 1
    blur = cv2.GaussianBlur(m2, (k, k), SIGMA)
    rebin = ((blur > 127) * 255).astype(np.uint8)
    smooth = cv2.resize(rebin, (W, H), interpolation=cv2.INTER_AREA) > 127
    inter = (smooth & src).sum()
    union = (smooth | src).sum()
    cs, _ = cv2.findContours(smooth.astype(np.uint8), cv2.RETR_EXTERNAL,
                             cv2.CHAIN_APPROX_SIMPLE)
    c = max(cs, key=cv2.contourArea)
    ap = cv2.approxPolyDP(c, 1.5, True).reshape(-1, 2).astype(np.float64)
    pts = chaikin(ap, 2)
    return pts, inter / union


def chaikin(pts: np.ndarray, iters: int = 2) -> np.ndarray:
    for _ in range(iters):
        new = []
        m = len(pts)
        for i in range(m):
            a, b = pts[i], pts[(i + 1) % m]
            new.append(0.75 * a + 0.25 * b)
            new.append(0.25 * a + 0.75 * b)
        pts = np.array(new)
    return pts


swoosh_pts, iou_sw = idealize(swoosh_id)
comet_pts, iou_co = idealize(comet_id)
planet_pts, iou_pl = idealize(planet_id)
print(f"理想化 IoU: 轨道弧={iou_sw:.3f} 彗星={iou_co:.3f} 行星={iou_pl:.3f}")

# 卫星球：正 64 边形
bm = labs == ball_id
ys2, xs2 = np.where(bm)
bc = (float(xs2.mean()), float(ys2.mean()))
cb, _ = cv2.findContours((bm * 255).astype(np.uint8),
                         cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
dists = [np.hypot(p[0][0] - bc[0], p[0][1] - bc[1])
         for p in max(cb, key=cv2.contourArea)]
br = float(np.median(dists))
ball_pts = np.array([[bc[0] + br * math.cos(2 * math.pi * i / 64),
                      bc[1] + br * math.sin(2 * math.pi * i / 64)]
                     for i in range(64)])
print(f"卫星球: center=({bc[0]:.1f},{bc[1]:.1f}) r={br:.1f}")


def poly_area(p):
    x, y = p[:, 0], p[:, 1]
    return 0.5 * abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))


entries = []
for pts in (swoosh_pts, comet_pts, ball_pts, planet_pts):
    entries.append({
        "is_hole": False,
        "area": round(poly_area(pts), 1),
        "bbox": [round(float(pts[:, 0].min()), 1), round(float(pts[:, 1].min()), 1),
                 round(float(pts[:, 0].max() - pts[:, 0].min()) + 1, 1),
                 round(float(pts[:, 1].max() - pts[:, 1].min()) + 1, 1)],
        "pts": [[round(float(x), 2), round(float(y), 2)] for x, y in pts],
    })
doc = {
    "canvas": [W, H],
    "bbox": [round(min(e["bbox"][0] for e in entries), 1),
             round(min(e["bbox"][1] for e in entries), 1),
             round(max(e["bbox"][0] + e["bbox"][2] for e in entries) - 1, 1),
             round(max(e["bbox"][1] + e["bbox"][3] for e in entries) - 1, 1)],
    "shapes": entries,
}
json.dump(doc, open(OUT, "w"))
print(f"已写 {OUT}: bbox={doc['bbox']} areas=" +
      ", ".join(f"{e['area']:.0f}" for e in entries))
