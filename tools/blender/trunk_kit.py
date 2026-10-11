"""Generate the modular tree-trunk kit.

Run:
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/trunk_kit.py

Writes assets/source/trunk_kit.blend (editable) and assets/trees/trunk_kit.glb.

Every segment shares one joint: a 32-vertex ring whose radius profile (8 bark
ridges) and vertex colour depend only on angle. Features (twist, sway, knots,
burls, moss, stubs) fade to zero with zero slope before each end, so any
segment stacks on any other, and rotations in 45 degree steps also match.
Blender is Z-up; glTF export converts to Godot's Y-up. Units are game units.

Sockets: each piece exports child empties named "<piece>_socket_<n>" marking where
the next piece attaches (position, tilt and uniform scale). Straight pieces have
one socket 4 units up; lean pieces tilt it; forks have two or three; tops none.
Because a socket only moves, turns and uniformly scales the standard joint, the
joint still matches. Godot grows background trees by following sockets.
"""

import math
import os
import random

import bmesh
import bpy
from mathutils import Matrix, Vector, noise

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(ROOT, "assets", "source", "trunk_kit.blend")
GLB_PATH = os.path.join(ROOT, "assets", "trees", "trunk_kit.glb")

SEGMENT_HEIGHT = 4.0
RADIUS = 0.52
RING = 32
ROW = 0.2
END_BLEND = 0.2  # fraction of the segment at each end that eases back to the joint

BARK_LIGHT = (0.63, 0.46, 0.37)
BARK_DARK = (0.34, 0.24, 0.21)
MOSS = (0.47, 0.56, 0.29)
LICHEN = (0.78, 0.75, 0.62)
HEARTWOOD = (0.80, 0.64, 0.47)


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def ridge(theta):
    """Joint bark profile in [0, 1]; periodic every 45 degrees."""
    return 0.5 + 0.35 * math.cos(8 * theta) + 0.15 * math.cos(16 * theta + 0.7)


def joint_radius(theta):
    return RADIUS * (1.0 + 0.15 * (ridge(theta) - 0.5))


def body_weight(v):
    """0 at both joints (with zero slope), 1 through the middle."""
    return smoothstep(0.0, END_BLEND, v) * smoothstep(1.0, 1.0 - END_BLEND, v)


class Segment:
    """A ring-stacked trunk surface with per-vertex colour, built as a bmesh."""

    def __init__(self, name, seed):
        self.name = name
        self.rng = random.Random(seed)
        self.seed = seed
        self.bm = bmesh.new()
        self.color = self.bm.loops.layers.float_color.new("Col")
        self.vertex_colors = {}
        self.sockets = [Matrix.Translation((0.0, 0.0, SEGMENT_HEIGHT))]

    def noise(self, x, y, z):
        return noise.noise(Vector((x + self.seed * 13.1, y, z)))

    def surface(self, z0, z1, radius_fn, color_fn, center_fn=None, cap_top=False):
        rows = max(2, round((z1 - z0) / ROW))
        rings = []
        for j in range(rows + 1):
            z = z0 + (z1 - z0) * j / rows
            ring = []
            for i in range(RING):
                theta = math.tau * i / RING
                r = radius_fn(theta, z)
                cx, cy = center_fn(z) if center_fn else (0.0, 0.0)
                vert = self.bm.verts.new((cx + r * math.cos(theta), cy + r * math.sin(theta), z))
                self.vertex_colors[vert] = color_fn(theta, z)
                ring.append(vert)
            rings.append(ring)
        for j in range(rows):
            for i in range(RING):
                a, b = rings[j][i], rings[j][(i + 1) % RING]
                c, d = rings[j + 1][(i + 1) % RING], rings[j + 1][i]
                self.bm.faces.new((a, b, c, d))
        if cap_top:
            top = rings[-1]
            cx = sum(v.co.x for v in top) / RING
            cy = sum(v.co.y for v in top) / RING
            tip = self.bm.verts.new((cx, cy, top[0].co.z + 0.12))
            self.vertex_colors[tip] = BARK_DARK
            for i in range(RING):
                self.bm.faces.new((top[i], top[(i + 1) % RING], tip))

    def sweep(self, a, b, radius_fn, color_fn, cap_end=False):
        """Rings swept from frame a to frame b (4x4: location, rotation, uniform scale).

        The ring lies in each frame's XY plane. Rotation and scale ease in and out
        (zero slope at both ends) so each end is locally a straight joint.
        radius_fn/color_fn take (theta, v, z) in unscaled joint units.
        """
        la, ra, sa = a.decompose()
        lb, rb, sb = b.decompose()
        axis_a = ra @ Vector((0, 0, 1))
        axis_b = rb @ Vector((0, 0, 1))
        span = (lb - la).length
        d = span / 3.0
        p0, p1, p2, p3 = la, la + axis_a * d, lb - axis_b * d, lb
        rows = max(6, round(span / ROW))
        rings = []
        for j in range(rows + 1):
            v = j / rows
            u = 1.0 - v
            pos = p0 * u ** 3 + p1 * 3 * u * u * v + p2 * 3 * u * v * v + p3 * v ** 3
            e = smoothstep(0.0, 1.0, v)
            rot = ra.slerp(rb, e)
            scale = sa.x + (sb.x - sa.x) * e
            ring = []
            for i in range(RING):
                theta = math.tau * i / RING
                r = radius_fn(theta, v, v * span) * scale
                vert = self.bm.verts.new(pos + rot @ Vector((r * math.cos(theta), r * math.sin(theta), 0.0)))
                self.vertex_colors[vert] = color_fn(theta, v, v * span)
                ring.append(vert)
            rings.append(ring)
        for j in range(rows):
            for i in range(RING):
                self.bm.faces.new((rings[j][i], rings[j][(i + 1) % RING], rings[j + 1][(i + 1) % RING], rings[j + 1][i]))
        if cap_end:
            tip = self.bm.verts.new(lb + axis_b * 0.05)
            self.vertex_colors[tip] = BARK_DARK
            for i in range(RING):
                self.bm.faces.new((rings[-1][i], rings[-1][(i + 1) % RING], tip))

    def limb(self, start, direction, length, r0, r1, sides=12, rows=8, cap_color=None):
        """Tapered round limb (branch stub or crown fork), optionally with a cut face."""
        direction = Vector(direction).normalized()
        side = direction.orthogonal().normalized()
        up = direction.cross(side).normalized()
        rings = []
        for j in range(rows + 1):
            t = j / rows
            center = Vector(start) + direction * (length * t)
            r = r0 + (r1 - r0) * t
            ring = []
            for i in range(sides):
                a = math.tau * i / sides
                offset = side * math.cos(a) + up * math.sin(a)
                vert = self.bm.verts.new(center + offset * r * (1.0 + 0.08 * math.cos(4 * a)))
                self.vertex_colors[vert] = mix(BARK_DARK, BARK_LIGHT, 0.5 + 0.5 * math.cos(4 * a))
                ring.append(vert)
            rings.append(ring)
        for j in range(rows):
            for i in range(sides):
                self.bm.faces.new((rings[j][i], rings[j][(i + 1) % sides], rings[j + 1][(i + 1) % sides], rings[j + 1][i]))
        end = rings[-1]
        tip_center = Vector(start) + direction * length
        if cap_color:
            # Cut face: pale heartwood ring with a darker centre.
            tip = self.bm.verts.new(tip_center)
            self.vertex_colors[tip] = mix(cap_color, BARK_DARK, 0.35)
            for v in end:
                self.vertex_colors[v] = BARK_DARK
            inner = []
            for v in end:
                iv = self.bm.verts.new(tip_center + (v.co - tip_center) * 0.8)
                self.vertex_colors[iv] = cap_color
                inner.append(iv)
            for i in range(sides):
                self.bm.faces.new((end[i], end[(i + 1) % sides], inner[(i + 1) % sides], inner[i]))
                self.bm.faces.new((inner[i], inner[(i + 1) % sides], tip))
        else:
            tip = self.bm.verts.new(tip_center + direction * r1)
            self.vertex_colors[tip] = BARK_DARK
            for i in range(sides):
                self.bm.faces.new((end[i], end[(i + 1) % sides], tip))

    def finish(self):
        for face in self.bm.faces:
            for loop in face.loops:
                # Stored as sRGB values: Godot treats imported vertex colours as sRGB
                # and linearises them itself, so linear values would darken twice.
                loop[self.color] = (*self.vertex_colors[loop.vert], 1.0)
        mesh = bpy.data.meshes.new(self.name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        for poly in mesh.polygons:
            poly.use_smooth = True
        mesh.color_attributes.active_color_index = 0
        mesh.color_attributes.render_color_index = 0
        obj = bpy.data.objects.new(self.name, mesh)
        return obj


def bark_color(seg, theta, z, w, moss=0.0, lichen=True):
    """Joint colour depends only on angle; mottling and moss fade in with w."""
    base = mix(BARK_DARK, BARK_LIGHT, ridge(theta) ** 1.3)
    mottle = seg.noise(math.cos(theta) * 2.0, math.sin(theta) * 2.0, z * 1.5)
    base = mix(base, mix(BARK_DARK, BARK_LIGHT, 0.5 + 0.5 * mottle), 0.35 * w)
    if lichen and w > 0:
        spot = seg.noise(math.cos(theta) * 6.0, math.sin(theta) * 6.0, z * 5.0)
        base = mix(base, LICHEN, smoothstep(0.55, 0.65, spot) * 0.6 * w)
    if moss > 0:
        base = mix(base, MOSS, moss * w)
    return base


def mid_segment(name, seed, twist=0.0, sway=0.0, bulge=0.0, knot=None, burl=None, moss=None):
    seg = Segment(name, seed)
    sway_angle = seg.rng.uniform(0, math.tau)

    def weight(z):
        return body_weight(z / SEGMENT_HEIGHT)

    def center(z):
        s = sway * weight(z) * math.sin(math.pi * z / SEGMENT_HEIGHT)
        return (s * math.cos(sway_angle), s * math.sin(sway_angle))

    def bump(theta, z, spec):
        theta0, z0, size, height = spec
        d_theta = math.atan2(math.sin(theta - theta0), math.cos(theta - theta0)) * RADIUS
        d2 = (d_theta ** 2 + (z - z0) ** 2) / (size ** 2)
        return height * math.exp(-d2)

    def radius(theta, z):
        w = weight(z)
        t = theta + twist * w * (z / SEGMENT_HEIGHT - 0.5)
        r = joint_radius(t)
        # Body-only bark variation and gentle swelling.
        r += RADIUS * w * (0.06 * seg.noise(math.cos(theta) * 1.5, math.sin(theta) * 1.5, z * 0.5) + bulge * math.sin(math.pi * z / SEGMENT_HEIGHT))
        if knot:
            outer = bump(theta, z, knot)
            eye = bump(theta, z, (knot[0], knot[1], knot[2] * 0.4, knot[3] * 1.6))
            r += w * (outer - eye)
        if burl:
            lumps = 0.6 + 0.4 * seg.noise(math.cos(theta) * 4.0, math.sin(theta) * 4.0, z * 3.0)
            r += w * bump(theta, z, burl) * lumps
        return r

    def color(theta, z):
        w = weight(z)
        t = theta + twist * w * (z / SEGMENT_HEIGHT - 0.5)
        moss_amount = 0.0
        if moss:
            theta0, spread = moss
            facing = 0.5 + 0.5 * math.cos(theta - theta0)
            patch = seg.noise(math.cos(theta) * 3.0, math.sin(theta) * 3.0, z * 1.6)
            fine = seg.noise(math.cos(theta) * 9.0, math.sin(theta) * 9.0, z * 6.0)
            moss_amount = smoothstep(0.55, 0.8, facing * spread + 0.45 * patch + 0.15 * fine)
        c = bark_color(seg, t, z, w, moss_amount)
        if knot:
            ring = bump(theta, z, (knot[0], knot[1], knot[2] * 0.55, 1.0))
            c = mix(c, BARK_DARK, 0.7 * ring * w)
        return c

    seg.surface(0.0, SEGMENT_HEIGHT, radius, color, center)
    return seg


def base_segment(name, seed, roots=5, spread=1.0):
    seg = Segment(name, seed)
    offsets = [seg.rng.uniform(-0.25, 0.25) for _ in range(roots)]
    strengths = [seg.rng.uniform(0.6, 1.0) for _ in range(roots)]

    def flare(theta, z):
        # Root buttresses spread near the ground and fade by ~1.6 units up.
        f = smoothstep(2.0 * spread, -0.6, z) ** 2.2
        lobes = 0.0
        for k in range(roots):
            a = math.tau * k / roots + offsets[k]
            lobes = max(lobes, strengths[k] * max(0.0, math.cos(theta - a)) ** 14)
        return f, lobes

    def weight(z):
        # Full detail down to the ground; eases back to the joint only at the top.
        return smoothstep(SEGMENT_HEIGHT, SEGMENT_HEIGHT * (1.0 - END_BLEND), z)

    def radius(theta, z):
        w = weight(z)
        r = joint_radius(theta)
        r += RADIUS * w * 0.03 * seg.noise(math.cos(theta) * 1.5, math.sin(theta) * 1.5, z * 0.8)
        f, lobes = flare(theta, z)
        return r + RADIUS * f * (0.25 + 2.6 * lobes) * spread

    def color(theta, z):
        w = weight(z)
        f, lobes = flare(theta, z)
        damp = smoothstep(1.2, -0.4, z)
        c = bark_color(seg, theta, z, max(w, f))
        return mix(c, MOSS, 0.55 * damp * (0.4 + 0.6 * lobes))

    seg.surface(-0.6, SEGMENT_HEIGHT, radius, color)
    return seg


def top_segment(name, seed, forks=2):
    seg = Segment(name, seed)

    def taper(z):
        return 1.0 - 0.6 * smoothstep(SEGMENT_HEIGHT * END_BLEND, SEGMENT_HEIGHT, z)

    def radius(theta, z):
        w = smoothstep(0.0, END_BLEND, z / SEGMENT_HEIGHT)
        r = joint_radius(theta) * taper(z)
        return r + RADIUS * w * 0.03 * seg.noise(math.cos(theta) * 1.5, math.sin(theta) * 1.5, z * 0.8)

    def color(theta, z):
        w = smoothstep(0.0, END_BLEND, z / SEGMENT_HEIGHT)
        return bark_color(seg, theta, z, w)

    seg.surface(0.0, SEGMENT_HEIGHT, radius, color, cap_top=True)
    seg.sockets = []
    for k in range(forks):
        angle = math.tau * k / forks + seg.rng.uniform(-0.4, 0.4)
        z = seg.rng.uniform(2.0, 3.2)
        out = Vector((math.cos(angle), math.sin(angle), 0.0))
        start = out * RADIUS * 0.4 * taper(z) + Vector((0, 0, z))
        seg.limb(start, out * 0.7 + Vector((0, 0, 1.0)), seg.rng.uniform(2.2, 3.0), RADIUS * 0.42, RADIUS * 0.14)
    return seg


def stub_segment(name, seed):
    seg = mid_segment(name, seed, twist=0.3, sway=0.08)
    angle = -math.pi / 2 + seg.rng.uniform(-0.5, 0.5)
    z = SEGMENT_HEIGHT * 0.5
    out = Vector((math.cos(angle), math.sin(angle), 0.0))
    seg.limb(out * RADIUS * 0.7 + Vector((0, 0, z)), out + Vector((0, 0, 0.35)), 0.65, RADIUS * 0.34, RADIUS * 0.27, cap_color=HEARTWOOD)
    return seg


def tilt(azimuth, angle):
    """Rotation that leans the +Z axis by angle toward the azimuth direction."""
    return Matrix.Rotation(azimuth, 4, "Z") @ Matrix.Rotation(angle, 4, "Y") @ Matrix.Rotation(-azimuth, 4, "Z")


def bark_fns(seg, twist=0.3):
    def radius(theta, v, z):
        w = body_weight(v)
        t = theta + twist * w * (v - 0.5)
        return joint_radius(t) + RADIUS * w * 0.06 * seg.noise(math.cos(theta) * 1.5, math.sin(theta) * 1.5, z * 0.5)

    def color(theta, v, z):
        w = body_weight(v)
        return bark_color(seg, theta + twist * w * (v - 0.5), z, w)

    return radius, color


def lean_segment(name, seed, angle, scale, shift=0.0):
    """A curving segment whose top joint is tilted (and optionally shifted sideways for an S-bend)."""
    seg = Segment(name, seed)
    length = SEGMENT_HEIGHT * 0.9
    if angle > 0:
        x = length * (1.0 - math.cos(angle)) / angle
        z = length * math.sin(angle) / angle
    else:
        x, z = shift, length
    end = Matrix.Translation((x, 0.0, z)) @ tilt(0.0, angle) @ Matrix.Scale(scale, 4)
    radius, color = bark_fns(seg, seg.rng.uniform(-0.8, 0.8))
    seg.sweep(Matrix(), end, radius, color)
    seg.sockets = [end]
    return seg


def fork_segment(name, seed, limbs):
    """A crotch: a tapering core with limbs that emerge from inside it.

    limbs: (azimuth, tilt angle, end scale, end height, spread) per limb. Each limb
    starts hidden inside the core and ends at a standard joint (its socket).
    """
    seg = Segment(name, seed)
    radius, color = bark_fns(seg)
    seg.sweep(Matrix(), Matrix.Translation((0, 0, 1.8)) @ Matrix.Scale(0.6, 4), radius, color, cap_end=True)
    seg.sockets = []
    for azimuth, angle, scale, height, spread in limbs:
        direction = Vector((math.cos(azimuth), math.sin(azimuth), 0.0))
        start = Matrix.Translation(direction * spread * 0.12 + Vector((0, 0, 0.6))) @ Matrix.Scale(0.62, 4)
        end = Matrix.Translation(direction * (spread + height * math.sin(angle) * 0.5) + Vector((0, 0, height))) @ tilt(azimuth, angle) @ Matrix.Scale(scale, 4)
        limb_radius, limb_color = bark_fns(seg, seg.rng.uniform(-0.6, 0.6))
        seg.sweep(start, end, limb_radius, limb_color)
        seg.sockets.append(end)
    return seg


def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    kit = bpy.data.collections.new("trunk_kit")
    bpy.context.scene.collection.children.link(kit)
    segments = [
        base_segment("trunk_base_a", 11),
        base_segment("trunk_base_b", 12, roots=4),
        base_segment("trunk_base_wide", 13, roots=6, spread=1.6),
        mid_segment("trunk_mid_plain_a", 21, twist=0.4, sway=0.12),
        mid_segment("trunk_mid_plain_b", 22, twist=-0.6, sway=0.14, bulge=0.07),
        mid_segment("trunk_mid_twist", 23, twist=2.2, sway=0.08),
        mid_segment("trunk_mid_knot", 24, twist=0.3, sway=0.08, knot=(-1.4, 2.1, 0.34, 0.17)),
        mid_segment("trunk_mid_burl", 25, sway=0.06, burl=(-1.9, 1.8, 0.55, 0.32)),
        stub_segment("trunk_mid_stub", 26),
        mid_segment("trunk_mid_moss", 27, twist=-0.3, sway=0.05, moss=(-1.57, 0.9)),
        top_segment("trunk_top_a", 31),
        top_segment("trunk_top_b", 32, forks=3),
        lean_segment("trunk_lean_a", 41, 0.22, 0.92),
        lean_segment("trunk_lean_b", 42, 0.36, 0.88),
        lean_segment("trunk_lean_s", 43, 0.0, 0.94, shift=0.7),
        fork_segment("trunk_fork_even", 51, [(0.0, 0.42, 0.74, 3.6, 0.45), (math.pi, 0.4, 0.72, 3.4, 0.45)]),
        fork_segment("trunk_fork_leader", 52, [(0.0, 0.12, 0.86, 3.8, 0.15), (math.pi, 0.7, 0.58, 3.0, 0.5)]),
        fork_segment("trunk_fork_three", 53, [(0.0, 0.5, 0.62, 3.4, 0.45), (2.1, 0.5, 0.6, 3.3, 0.45), (4.2, 0.45, 0.6, 3.5, 0.45)]),
    ]
    for index, seg in enumerate(segments):
        obj = seg.finish()
        obj.location.x = index * 2.5  # layout only; Godot uses mesh-local data
        kit.objects.link(obj)
        for k, socket in enumerate(seg.sockets):
            marker = bpy.data.objects.new("%s_socket_%d" % (seg.name, k), None)
            marker.empty_display_type = "ARROWS"
            marker.empty_display_size = 0.5
            marker.parent = obj
            marker.matrix_basis = socket
            kit.objects.link(marker)

    # Preview stack (not exported): shows segments meeting at joints.
    preview = bpy.data.collections.new("preview_stack")
    bpy.context.scene.collection.children.link(preview)
    names = ["trunk_base_a", "trunk_mid_knot", "trunk_mid_moss", "trunk_mid_twist", "trunk_mid_stub", "trunk_top_b"]
    for level, name in enumerate(names):
        src = bpy.data.objects[name]
        dup = bpy.data.objects.new(name + "_preview", src.data)
        dup.location = (-4.0, 0.0, level * SEGMENT_HEIGHT)
        dup.rotation_euler.z = math.radians(45 * level)
        preview.objects.link(dup)

    os.makedirs(os.path.dirname(BLEND_PATH), exist_ok=True)
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)

    bpy.ops.object.select_all(action="DESELECT")
    for obj in kit.objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(filepath=GLB_PATH, export_format="GLB", use_selection=True,
        export_vertex_color="ACTIVE", export_all_vertex_colors=False, export_normals=True,
        export_materials="NONE", export_yup=True)
    print("TRUNK KIT: %d segments -> %s" % (len(segments), GLB_PATH))


build()
