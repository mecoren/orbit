"""
Generate Orbit app icon with transparent background (v7 - final tuning).

Refined proportions:
- Dot: smaller, clearly separate from C ring end
- Checkmark: slightly larger, better centered
- Clean seamless C + swoosh connection
"""

from PIL import Image, ImageDraw
import math

FINAL_SIZE = 1024
OUTPUT = "apps/desktop/src-tauri/icons/icon-transparent.png"

SIZE = FINAL_SIZE
STROKE = 90
BLUE = (74, 128, 240, 255)

cx = cy = SIZE // 2

def circle_centerline(cx, cy, radius, start_deg, end_deg, steps=700):
    pts = []
    for i in range(steps + 1):
        t = start_deg + (end_deg - start_deg) * i / steps
        angle = math.radians(t)
        pts.append((cx + radius * math.cos(angle),
                    cy + radius * math.sin(angle)))
    return pts

def cubic_bezier(p0, p1, p2, p3, steps=700):
    pts = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = (mt**3*p0[0] + 3*mt**2*t*p1[0] + 3*mt*t**2*p2[0] + t**3*p3[0])
        y = (mt**3*p0[1] + 3*mt**2*t*p1[1] + 3*mt*t**2*p2[1] + t**3*p3[1])
        pts.append((x, y))
    return pts

def stroke_polygon(centerline, thickness):
    half_t = thickness / 2
    left_pts, right_pts = [], []
    n = len(centerline)
    for i in range(n):
        if i == 0:
            dx = centerline[1][0] - centerline[0][0]
            dy = centerline[1][1] - centerline[0][1]
        elif i == n - 1:
            dx = centerline[n-1][0] - centerline[n-2][0]
            dy = centerline[n-1][1] - centerline[n-2][1]
        else:
            dx = centerline[i+1][0] - centerline[i-1][0]
            dy = centerline[i+1][1] - centerline[i-1][1]
        length = math.sqrt(dx*dx + dy*dy)
        if length < 0.001:
            continue
        dx /= length
        dy /= length
        nx, ny = -dy, dx
        x, y = centerline[i]
        left_pts.append((x + nx * half_t, y + ny * half_t))
        right_pts.append((x - nx * half_t, y - ny * half_t))
    return left_pts + list(reversed(right_pts))

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# === 1. C-shaped thick ring ===
outer_r = 395
center_r = outer_r - STROKE / 2
arc_centerline = circle_centerline(cx, cy, center_r, 200, 320, steps=800)
c_polygon = stroke_polygon(arc_centerline, STROKE)
d.polygon(c_polygon, fill=BLUE)

# === 2. Dot circle - sits next to C ring end ===
# Dot at angle 330, radius ~stroke thickness, touching C ring
dot_angle = math.radians(332)
dot_r = 52  # ~stroke thickness diameter
# Position just beyond C ring outer edge so dot touches ring end
dot_x = cx + int((outer_r + dot_r * 0.8) * math.cos(dot_angle))
dot_y = cy + int((outer_r + dot_r * 0.8) * math.sin(dot_angle))
d.ellipse([dot_x - dot_r, dot_y - dot_r, dot_x + dot_r, dot_y + dot_r], fill=BLUE)

# === 3. Checkmark ===
ck_centerline = [
    (cx - 115, cy + 65),
    (cx - 10, cy + 115),
    (cx + 145, cy - 100)
]
ck_w = 75
ck_polygon = stroke_polygon(ck_centerline, ck_w)
d.polygon(ck_polygon, fill=BLUE)
d.ellipse([ck_centerline[1][0]-ck_w//2, ck_centerline[1][1]-ck_w//2,
           ck_centerline[1][0]+ck_w//2, ck_centerline[1][1]+ck_w//2], fill=BLUE)

# === 4. Orbital swoosh - seamless connection to C ring ends ===
c_start_angle = math.radians(200)
c_end_angle = math.radians(320)
c_start_pt = (cx + center_r * math.cos(c_start_angle),
              cy + center_r * math.sin(c_start_angle))
c_end_pt = (cx + center_r * math.cos(c_end_angle),
            cy + center_r * math.sin(c_end_angle))

sw_p0 = c_start_pt
sw_p1 = (cx - 340, cy + 345)
sw_p2 = (cx + 340, cy + 345)
sw_p3 = c_end_pt

swoosh_centerline = cubic_bezier(sw_p0, sw_p1, sw_p2, sw_p3, steps=800)
sw_polygon = stroke_polygon(swoosh_centerline, STROKE)
d.polygon(sw_polygon, fill=BLUE)

# Save
img.save(OUTPUT, "PNG")
print(f"Saved: {OUTPUT} ({SIZE}x{SIZE}, RGBA transparent)")
