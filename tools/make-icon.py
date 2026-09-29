#!/usr/bin/env python3
"""Renders the Glass Rail app icon at 1024x1024 with no alpha channel.

A faithful redraw of v4's app/icon.tsx (the web app's favicon and Apple touch
icon): a deep blue 155-degree gradient with a cool glow top left and a warm glow
bottom right, a glassy top sheen, a luminous orb, and two rails beneath it.

    python3 tools/make-icon.py GlassRail/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
"""
import sys

import numpy as np
from PIL import Image, ImageFilter

S = 1024
yy, xx = np.mgrid[0:S, 0:S].astype(np.float64) + 0.5


def hex_rgb(value):
    value = value.lstrip("#")
    return np.array([int(value[i : i + 2], 16) for i in (0, 2, 4)], dtype=np.float64) / 255


def over(base, color, alpha):
    """Composite `color` with per-pixel `alpha` over an opaque RGB base."""
    a = np.clip(alpha, 0, 1)[..., None]
    return base * (1 - a) + color * a


def linear_gradient(angle_deg, stops):
    """CSS linear-gradient(angle, stops) over the square."""
    t = np.deg2rad(angle_deg)
    dx, dy = np.sin(t), -np.cos(t)  # CSS: 0deg points up, 90deg right
    half = (abs(dx) + abs(dy)) * S / 2  # CSS gradient line half-length
    proj = ((xx - S / 2) * dx + (yy - S / 2) * dy + half) / (2 * half)
    positions = np.array([p for p, _ in stops])
    out = np.zeros((S, S, 3))
    for channel in range(3):
        out[..., channel] = np.interp(proj, positions, [c[channel] for _, c in stops])
    return out


def radial_alpha(cx, cy, peak, reach):
    """CSS radial-gradient(circle at cx cy, color, transparent reach) alpha."""
    px, py = cx * S, cy * S
    far = max(np.hypot(px - x, py - y) for x in (0, S) for y in (0, S))
    d = np.hypot(xx - px, yy - py) / (far * reach)
    return peak * np.clip(1 - d, 0, 1)


def blurred_shape(mask, blur_px):
    """Gaussian blur of a 0..1 mask (CSS blur radius is about 2 sigma)."""
    img = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(blur_px / 2)), dtype=np.float64) / 255


def disc(cx, cy, r):
    return np.clip(r - np.hypot(xx - cx, yy - cy) + 0.5, 0, 1)


def pill(cx, cy, w, h):
    r = h / 2
    x = np.clip(xx, cx - w / 2 + r, cx + w / 2 - r)
    return np.clip(r - np.hypot(xx - x, yy - cy) + 0.5, 0, 1)


# Background: linear-gradient(155deg, #3a4f7c 0%, #243358 38%, #131c34 100%)
img = linear_gradient(155, [(0, hex_rgb("3a4f7c")), (0.38, hex_rgb("243358")), (1, hex_rgb("131c34"))])
# radial-gradient(circle at 25% 22%, rgba(140,180,250,0.6), transparent 55%)
img = over(img, np.array([140, 180, 250]) / 255, radial_alpha(0.25, 0.22, 0.6, 0.55))
# radial-gradient(circle at 78% 82%, rgba(220,168,100,0.5), transparent 55%)
img = over(img, np.array([220, 168, 100]) / 255, radial_alpha(0.78, 0.82, 0.5, 0.55))
# linear-gradient(180deg, rgba(255,255,255,0.26), transparent 38%)
img = over(img, np.ones(3), 0.26 * np.clip(1 - (yy / S) / 0.38, 0, 1))

# Column: orb (0.36), gap 0.06, rail (0.04), gap 0.06, rail (0.04); centered.
orb = 0.36 * S
rail_h = max(2, 0.04 * S)
gap = 0.06 * S
top = (S - (orb + 2 * gap + 2 * rail_h)) / 2
cx = S / 2
orb_cy = top + orb / 2
rail1_cy = top + orb + gap + rail_h / 2
rail2_cy = rail1_cy + rail_h + gap

orb_mask = disc(cx, orb_cy, orb / 2)
# box-shadow: 0 0.02s 0.08s rgba(0,0,0,0.35), 0 0 0.16s rgba(160,195,255,0.7), 0 0 0.32s rgba(120,170,255,0.45)
img = over(img, np.array([120, 170, 255]) / 255, 0.45 * blurred_shape(orb_mask, 0.32 * S))
img = over(img, np.array([160, 195, 255]) / 255, 0.70 * blurred_shape(orb_mask, 0.16 * S))
img = over(img, np.zeros(3), 0.35 * blurred_shape(disc(cx, orb_cy + 0.02 * S, orb / 2), 0.08 * S))

# Orb fill: radial-gradient(circle at 32% 28%, #fff 0%, #e2ecff 38%, #88a9ec 80%, #4a6db5 100%)
ox, oy = cx - orb / 2 + 0.32 * orb, orb_cy - orb / 2 + 0.28 * orb
far = max(np.hypot(ox - (cx + sx * orb / 2), oy - (orb_cy + sy * orb / 2)) for sx in (-1, 1) for sy in (-1, 1))
t = np.hypot(xx - ox, yy - oy) / far
fill = np.zeros((S, S, 3))
stops = [(0, hex_rgb("ffffff")), (0.38, hex_rgb("e2ecff")), (0.80, hex_rgb("88a9ec")), (1.0, hex_rgb("4a6db5"))]
for channel in range(3):
    fill[..., channel] = np.interp(t, [p for p, _ in stops], [c[channel] for _, c in stops])
img = over(img, fill, orb_mask)


def rail(cy, width, edge, middle, glow=None):
    global img
    mask = pill(cx, cy, width, rail_h)
    if glow is not None:
        img = over(img, np.ones(3), glow * blurred_shape(mask, 0.10 * S))
    # linear-gradient(90deg, edge, middle 50%, edge), white with varying alpha
    u = np.clip((xx - (cx - width / 2)) / width, 0, 1)
    alpha = np.interp(u, [0, 0.5, 1], [edge, middle, edge])
    img = over(img, np.ones(3), alpha * mask)


rail(rail1_cy, 0.55 * S, 0.25, 0.85, glow=0.45)
rail(rail2_cy, 0.55 * S * 0.7, 0.15, 0.55)

out = Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
path = sys.argv[1] if len(sys.argv) > 1 else "AppIcon-1024.png"
out.save(path, optimize=True)
print(f"wrote {path} {out.size} mode={out.mode}")
