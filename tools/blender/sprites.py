"""Paint distant-scenery sprites (trees, bushes, ferns) as PNGs with alpha.

Run:
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/sprites.py

Writes assets/sprites/*.png. Uses Blender only for its bundled numpy and PNG
writer. The style follows the references: scalloped leaf masses lit warm
yellow-green from the upper right, cool sage and soft pink in shade, and
slender warm trunks. Colours are mid-tone sRGB; the game adds depth haze.
"""

import math
import os
import random

import bpy
import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "assets", "sprites")

LEAF_SHADE = np.array([0.42, 0.52, 0.34])
LEAF_MID = np.array([0.58, 0.66, 0.38])
LEAF_LIGHT = np.array([0.82, 0.84, 0.50])
LEAF_PINK = np.array([0.82, 0.68, 0.64])
BARK_SHADE = np.array([0.46, 0.33, 0.30])
BARK_LIGHT = np.array([0.70, 0.52, 0.44])
FERN_SHADE = np.array([0.33, 0.47, 0.26])
FERN_LIGHT = np.array([0.62, 0.74, 0.38])
LIGHT = np.array([0.55, -0.83])  # upper right, image y points down


class Canvas:
    def __init__(self, width, height):
        self.w, self.h = width, height
        self.rgba = np.zeros((height, width, 4), np.float32)
        # Transparent pixels carry a leaf colour so filtered edges don't fringe dark.
        self.rgba[..., :3] = LEAF_MID
        self.y, self.x = np.mgrid[0:height, 0:width].astype(np.float32)

    def paint(self, alpha, rgb):
        a = alpha[..., None]
        self.rgba[..., :3] = self.rgba[..., :3] * (1 - a) + rgb * a
        self.rgba[..., 3:] = self.rgba[..., 3:] * (1 - a) + a

    def blob(self, cx, cy, r, shade, light, rng, lobes=None, pink=0.0):
        """Scalloped leaf cluster: lobed edge, two-tone light from the upper right."""
        x0, x1 = int(max(cx - r * 1.3, 0)), int(min(cx + r * 1.3, self.w))
        y0, y1 = int(max(cy - r * 1.3, 0)), int(min(cy + r * 1.3, self.h))
        if x1 <= x0 or y1 <= y0:
            return
        sub = (slice(y0, y1), slice(x0, x1))
        dx = (self.x[sub] - cx) / r
        dy = (self.y[sub] - cy) / r
        d = np.sqrt(dx * dx + dy * dy)
        angle = np.arctan2(dy, dx)
        lobes = lobes or rng.randint(7, 11)
        phase = rng.uniform(0, math.tau)
        edge = 1.0 + 0.10 * np.abs(np.sin(lobes * angle * 0.5 + phase)) - 0.05 + 0.04 * np.sin(lobes * 2.3 * angle + phase)
        alpha = np.clip((edge - d) * r * 0.8, 0, 1)
        facing = -(dx * LIGHT[0] + dy * LIGHT[1])
        lit = np.clip((facing + 0.15) * 2.2, 0, 1)
        lit = lit * lit * (3 - 2 * lit)
        rgb = shade + (light - shade) * lit[..., None]
        if pink:
            rgb = rgb + (LEAF_PINK - rgb) * pink * (1 - lit[..., None])
        # Each cluster gets its own slight value shift, like separate brush dabs.
        rgb = rgb * rng.uniform(0.94, 1.06)
        a = alpha[..., None]
        region = self.rgba[sub]
        region[..., :3] = region[..., :3] * (1 - a) + rgb * a
        region[..., 3:] = region[..., 3:] * (1 - a) + a

    def limb(self, x0, y0, x1, y1, r0, r1):
        """Tapered stroke with a lit right edge."""
        bx0, bx1 = int(max(min(x0, x1) - r0 - 2, 0)), int(min(max(x0, x1) + r0 + 2, self.w))
        by0, by1 = int(max(min(y0, y1) - r0 - 2, 0)), int(min(max(y0, y1) + r0 + 2, self.h))
        sub = (slice(by0, by1), slice(bx0, bx1))
        px, py = self.x[sub] - x0, self.y[sub] - y0
        vx, vy = x1 - x0, y1 - y0
        t = np.clip((px * vx + py * vy) / (vx * vx + vy * vy), 0, 1)
        dx, dy = px - vx * t, py - vy * t
        r = r0 + (r1 - r0) * t
        d = np.sqrt(dx * dx + dy * dy)
        alpha = np.clip((r - d) * 0.9, 0, 1)
        side = np.clip(0.5 + 0.5 * (dx * LIGHT[0] + dy * LIGHT[1]) / np.maximum(r, 1), 0, 1)
        rgb = BARK_SHADE + (BARK_LIGHT - BARK_SHADE) * side[..., None]
        a = alpha[..., None]
        region = self.rgba[sub]
        region[..., :3] = region[..., :3] * (1 - a) + rgb * a
        region[..., 3:] = region[..., 3:] * (1 - a) + a

    def save(self, name):
        img = bpy.data.images.new(name, self.w, self.h, alpha=True)
        # Blender images start at the bottom row.
        img.pixels.foreach_set(np.flipud(self.rgba).ravel())
        img.filepath_raw = os.path.join(OUT, name + ".png")
        img.file_format = "PNG"
        img.save()


def tree(name, seed, lean, forks):
    rng = random.Random(seed)
    c = Canvas(512, 1024)
    base = (256 - lean * 60, 1010)
    crotch = (256 + lean * 40, rng.uniform(520, 600))
    tips = []
    for k in range(forks):
        spread = (k - (forks - 1) / 2) * rng.uniform(110, 150) + lean * 40
        tips.append((min(max(crotch[0] + spread, 150), 362), rng.uniform(250, 360)))
    # Back canopy: cooler, pinker clusters behind the limbs.
    for _ in range(26):
        tx, ty = rng.choice(tips)
        c.blob(tx + rng.gauss(0, 60), ty + rng.gauss(10, 60), rng.uniform(42, 72), LEAF_SHADE, LEAF_MID, rng, pink=0.6)
    c.limb(base[0], base[1], crotch[0], crotch[1], 30, 18)
    for tx, ty in tips:
        c.limb(crotch[0], crotch[1], tx, ty + 40, 17, 7)
        for _ in range(3):
            c.limb(tx, ty + 60, tx + rng.uniform(-90, 90), ty + rng.uniform(-30, 60), 5, 2)
    # Front canopy: sunlit clusters.
    for _ in range(30):
        tx, ty = rng.choice(tips)
        c.blob(tx + rng.gauss(0, 55), ty + rng.gauss(-10, 55), rng.uniform(36, 64), LEAF_MID, LEAF_LIGHT, rng, pink=0.15)
    c.save(name)


def bush(name, seed, flowers):
    rng = random.Random(seed)
    c = Canvas(512, 256)
    for _ in range(16):
        c.blob(rng.uniform(80, 432), rng.uniform(150, 215), rng.uniform(40, 70), LEAF_SHADE, LEAF_MID, rng, pink=0.35)
    for _ in range(16):
        c.blob(rng.uniform(90, 422), rng.uniform(130, 205), rng.uniform(30, 55), LEAF_MID, LEAF_LIGHT, rng)
    for _ in range(flowers):
        x, y = rng.uniform(100, 412), rng.uniform(110, 210)
        c.blob(x, y, rng.uniform(4, 7), np.array([0.95, 0.93, 0.85]), np.array([1.0, 0.98, 0.92]), rng, lobes=5)
    # Keep the bottom edge flat so it sits on the ground.
    c.rgba[236:, :, 3] = 0
    c.save(name)


def fern(name, seed):
    rng = random.Random(seed)
    c = Canvas(256, 256)
    for k in range(7):
        angle = math.radians(-90 + (k - 3) * 17 + rng.uniform(-5, 5))
        length = rng.uniform(120, 150)
        curl = rng.uniform(0.0012, 0.0025) * (1 if k >= 3 else -1)
        for s in range(26):
            t = s / 25
            a = angle + curl * s * 8
            x = 128 + math.cos(a) * length * t
            y = 248 + math.sin(a) * length * t + 18 * t * t
            size = 9 * (1 - t) + 2.5
            for side in (-1, 1):
                ox = math.cos(a + side * 1.2) * size
                oy = math.sin(a + side * 1.2) * size
                c.blob(x + ox, y + oy, size * 0.6, FERN_SHADE, FERN_LIGHT, rng, lobes=6)
    c.save(name)


def leaf_sprig(name, seed):
    """Leaf card for 3D canopy clumps: a sprig of pointed leaves.

    RGB is a pale per-leaf value/hue variation that the leaf shader multiplies by
    each tree's leaf colour. Alpha is a soft distance field (0.5 at the leaf edge,
    rising inward), so the shader can erode leaves by raising the cut-off as a
    card turns edge-on to the camera.
    """
    rng = random.Random(seed)
    size = 256
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    field = np.zeros((size, size), np.float32)
    rgb = np.ones((size, size, 3), np.float32) * np.array([0.88, 0.90, 0.80])
    leaves = []
    # Stem runs up from the bottom centre; leaves alternate off it and one caps the tip.
    for k in range(9):
        t = (k + 1) / 9
        sx, sy = 128 + rng.uniform(-6, 6) * t, 246 - t * 150
        if k == 8:
            angle = math.radians(-90 + rng.uniform(-12, 12))
        else:
            side = -1 if k % 2 else 1
            angle = math.radians(-90 + side * rng.uniform(38, 62))
        leaves.append((sx, sy, angle, rng.uniform(62, 86) * (1.05 - t * 0.25), rng.uniform(0.38, 0.48)))
    for sx, sy, angle, length, width in leaves:
        dx, dy = math.cos(angle), math.sin(angle)
        px, py = x - sx, y - sy
        u = (px * dx + py * dy) / length          # along the leaf, 0 at the stalk
        v = (-px * dy + py * dx) / length         # across the leaf
        half = width * np.clip(np.sin(np.clip(u, 0, 1) * math.pi), 0, 1) ** 0.7 * 0.5
        dist = (half - np.abs(v)) * length        # pixels inside the edge
        leaf = np.clip(0.5 + dist / 18.0, 0, 1) * ((u > 0) & (u < 1))
        # Per leaf: value and warm/cool shift; darker toward the stalk; pale midrib.
        tone = np.array([rng.uniform(0.95, 1.08), rng.uniform(0.97, 1.05), rng.uniform(0.82, 1.0)]) * rng.uniform(0.82, 1.0)
        shade = (0.78 + 0.22 * np.clip(u * 1.6, 0, 1))[..., None]
        rib = np.clip(1 - np.abs(v) * length / 1.6, 0, 1)[..., None] * 0.12 * (u > 0.08)[..., None]
        colour = np.clip(tone * shade + rib, 0, 1)
        over = (leaf > field)[..., None]
        rgb = np.where(over, colour, rgb)
        field = np.maximum(field, leaf)
    # Thin pale stalk so the sprig reads as one piece up close; it stays faint in
    # the alpha field so it erodes first instead of lingering as a dark hair.
    stem = np.clip(0.5 + (1.5 - np.abs(x - 128)) / 3.0, 0, 0.6) * ((y > 150) & (y < 240))
    rgb = np.where((stem > field)[..., None], np.array([0.80, 0.82, 0.62]), rgb)
    field = np.maximum(field, stem)
    c = Canvas(size, size)
    c.rgba[..., :3] = rgb
    c.rgba[..., 3] = field
    c.save(name)


def build():
    os.makedirs(OUT, exist_ok=True)
    leaf_sprig("leaf_sprig", 31)
    tree("tree_a", 1, 0.0, 2)
    tree("tree_b", 2, 0.5, 2)
    tree("tree_c", 3, -0.3, 3)
    tree("tree_d", 4, 0.8, 1)
    bush("bush_a", 11, 0)
    bush("bush_b", 12, 14)
    bush("bush_c", 13, 4)
    fern("fern_a", 21)
    fern("fern_b", 22)
    print("SPRITES: written to", OUT)


build()
