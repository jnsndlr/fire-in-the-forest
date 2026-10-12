"""Generate the rigged, animated flying squirrel.

Run:
  /Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
      --python tools/blender/squirrel.py

Writes assets/source/squirrel.blend (editable) and assets/characters/squirrel.glb.
Pass `-- --preview` after the script to also render a contact sheet of every
action to assets/source/squirrel_preview.png.

The body is a union of soft ellipsoids (voxel remeshed, smoothed, decimated) with
crisp accents (eyes, eye rings, nose, ears) added after remeshing. Colour lives in
vertex colours written as sRGB values, as in the trunk kit. Skin weights come from
distance to bones, limited to the bones that can plausibly move each body part.

The squirrel faces +X with feet on Z = 0; the side-view camera looks from -Y.
Actions (24 fps, in place, no root motion):
  run    16-frame gallop loop (extended, front plant, gathered, hind push)
  jump   24-frame one-shot: crouch 0-4, launch 4-7, rise 7-12, stretch 12-16,
         reach for landing 16-20, land and recover 20-24
  glide  24-frame loop, limbs splayed with the membrane stretched between them
  idle   48-frame loop: standing, breathing, with a slow tail sway and ear flick
The glide membrane is a flank sheet whose outer edge rides two bones
(membrane_front/back) that copy the wrist and ankle positions with an animated
constraint influence: 0 while running (skin tucked along the flank), 1 gliding.
Export bakes the constraints, so Godot just sees bone tracks.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector, noise

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
BLEND_PATH = os.path.join(ROOT, "assets", "source", "squirrel.blend")
GLB_PATH = os.path.join(ROOT, "assets", "characters", "squirrel.glb")
PREVIEW_PATH = os.path.join(ROOT, "assets", "source", "squirrel_preview.png")

S = 2.0  # design units -> game units: nose to rump is about 0.9 game units
VOXEL = 0.0085
TARGET_TRIS = 9000
FPS = 24

BROWN = (0.66, 0.43, 0.26)
BROWN_DARK = (0.47, 0.29, 0.18)
TAIL_LIGHT = (0.86, 0.70, 0.52)
CREAM = (0.96, 0.89, 0.77)
PAW = (0.46, 0.31, 0.26)
PINK = (0.90, 0.62, 0.58)
EYE = (0.07, 0.06, 0.06)
NOSE = (0.22, 0.14, 0.13)
WHITE = (1.0, 1.0, 1.0)


FORE = 0.8  # squashes the front half lengthwise: a compact body under a big head


def X(x):
    return (x if x < 0 else x * FORE) * S


def v(x, y, z):
    return Vector((X(x), y * S, z * S))


def mix(a, b, t):
    t = min(max(t, 0.0), 1.0)
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


# ---------------------------------------------------------------- skeleton

L, R = 1, -1
SIDES = {"L": L, "R": R}

# name: (head, tail, parent). Design units; mirrored limbs are added below.
BONES = {
    "root": ((0, 0, 0), (0, 0, 0.06), None),
    "hips": ((-0.12, 0, 0.155), (0.02, 0, 0.165), "root"),
    "chest": ((0.02, 0, 0.165), (0.16, 0, 0.175), "hips"),
    "neck": ((0.16, 0, 0.175), (0.215, 0, 0.225), "chest"),
    "head": ((0.215, 0, 0.225), (0.33, 0, 0.215), "neck"),
}
TAIL_POINTS = [(-0.12, 0.16), (-0.19, 0.21), (-0.25, 0.28), (-0.32, 0.335), (-0.41, 0.365), (-0.50, 0.355)]
for i in range(5):
    (x0, z0), (x1, z1) = TAIL_POINTS[i], TAIL_POINTS[i + 1]
    BONES["tail%d" % (i + 1)] = ((x0, 0, z0), (x1, 0, z1), "hips" if i == 0 else "tail%d" % i)
ARM = [(0.12, 0.045, 0.15), (0.11, 0.058, 0.085), (0.135, 0.062, 0.03), (0.168, 0.062, 0.010)]
LEG = [(-0.07, 0.05, 0.14), (-0.01, 0.07, 0.085), (-0.08, 0.072, 0.034), (-0.008, 0.072, 0.008)]
EAR = [(0.235, 0.03, 0.28), (0.222, 0.042, 0.325)]
HEAD_C = (0.25, 0, 0.238)
HEAD_R = (0.074, 0.064, 0.066)


def mirror(p, s):
    return (p[0], p[1] * s, p[2])


for side, s in SIDES.items():
    a = [mirror(p, s) for p in ARM]
    g = [mirror(p, s) for p in LEG]
    BONES["arm_upper." + side] = (a[0], a[1], "chest")
    BONES["arm_lower." + side] = (a[1], a[2], "arm_upper." + side)
    BONES["hand." + side] = (a[2], a[3], "arm_lower." + side)
    BONES["thigh." + side] = (g[0], g[1], "hips")
    BONES["shin." + side] = (g[1], g[2], "thigh." + side)
    BONES["foot." + side] = (g[2], g[3], "shin." + side)
    BONES["ear." + side] = (mirror(EAR[0], s), mirror(EAR[1], s), "head")
    # Membrane edge anchors: rest tucked along the flank, glide pinned to wrist / ankle.
    BONES["membrane_front." + side] = ((0.10, 0.05 * s, 0.115), (0.10, 0.05 * s, 0.085), "chest")
    BONES["membrane_back." + side] = ((-0.05, 0.055 * s, 0.11), (-0.05, 0.055 * s, 0.08), "hips")

PART_BONES = {
    "body": ["hips", "chest", "neck"],
    "head": ["neck", "head"],
    "tail": ["hips"] + ["tail%d" % i for i in range(1, 6)],
}
for side in SIDES:
    PART_BONES["arm." + side] = ["chest", "arm_upper." + side, "arm_lower." + side, "hand." + side]
    PART_BONES["leg." + side] = ["hips", "thigh." + side, "shin." + side, "foot." + side]
    PART_BONES["haunch." + side] = ["hips", "thigh." + side]


# ---------------------------------------------------------------- shapes

class Prim:
    def __init__(self, center, radii, rot, part, color):
        self.center = Vector(center)
        self.radii = Vector(radii)
        self.rot = rot
        self.inv = rot.transposed()
        self.part = part
        self.color = color  # fn(p, n, prim) -> rgb

    def field(self, p):
        q = self.inv @ (p - self.center)
        return Vector((q.x / self.radii.x, q.y / self.radii.y, q.z / self.radii.z)).length - 1.0

    def local(self, p):
        return self.inv @ (p - self.center)


def add_ellipsoid(bm, center, radii, rot=None, point=0.0, segments=(24, 14)):
    rot = rot or Matrix.Identity(3)
    # BMesh reuses freed slots, so new verts can land anywhere in iteration order.
    before = set(bm.verts)
    bmesh.ops.create_uvsphere(bm, u_segments=segments[0], v_segments=segments[1], radius=1.0)
    verts = [vert for vert in bm.verts if vert not in before]
    for vert in verts:
        c = vert.co
        if point:
            # Teardrop: pinch the upper half toward a tip.
            k = 1.0 - point * max(c.z, 0.0)
            c = Vector((c.x * k, c.y * k, c.z * (1.0 + 0.35 * point * max(c.z, 0.0))))
        vert.co = rot @ Vector((c.x * radii[0], c.y * radii[1], c.z * radii[2])) + Vector(center)
    return verts


def along(a, b):
    """Rotation taking +X to the direction a->b, and the segment length."""
    d = Vector(b) - Vector(a)
    return Vector((1, 0, 0)).rotation_difference(d.normalized()).to_matrix(), d.length


def pitch_rot(angle):
    """Tilt +X toward +Z by angle (nose up)."""
    return Matrix.Rotation(-angle, 3, "Y")


# Colour functions -----------------------------------------------------------

def paint_noise(p, scale=9.0):
    return noise.noise(p * scale / S)


def fur(base, p, n, dark=0.0):
    # Darker along the spine, a little painterly mottling everywhere.
    c = mix(base, BROWN_DARK, smoothstep(0.55, 0.95, n.z) * 0.55 + dark)
    return mix(c, (1, 1, 1) if paint_noise(p) > 0 else BROWN_DARK, abs(paint_noise(p)) * 0.12)


def body_color(p, n, prim):
    belly = smoothstep(-0.05, -0.45, n.z)
    # Cream bib down the front of the chest.
    belly = max(belly, smoothstep(X(0.08), X(0.14), p.x) * smoothstep(0.17 * S, 0.12 * S, p.z) * smoothstep(-0.2, 0.3, n.x))
    return mix(fur(BROWN, p, n), CREAM, belly)


def head_color(p, n, prim):
    chin = smoothstep(0.0, -0.4, n.z)
    muzzle = smoothstep(X(0.28), X(0.31), p.x) * smoothstep(0.23 * S, 0.21 * S, p.z)
    cheek = smoothstep(0.24 * S, 0.215 * S, p.z) * smoothstep(0.5, 0.85, abs(n.y))
    return mix(fur(BROWN, p, n), CREAM, max(chin, muzzle, cheek))


def leg_color(p, n, prim):
    inner = smoothstep(0.3, 0.8, -n.y * math.copysign(1.0, p.y)) * 0.6
    c = mix(fur(BROWN, p, n), CREAM, inner)
    return mix(c, PAW, smoothstep(0.03 * S, 0.012 * S, p.z))


def tail_color(p, n, prim):
    t = smoothstep(-0.2 * S, -0.52 * S, p.x)  # base -> tip
    q = prim.local(p)
    rim = smoothstep(0.6, 1.0, abs(q.z / prim.radii.z))
    c = mix(fur(BROWN, p, n, dark=0.1), TAIL_LIGHT, rim * 0.5 + t * 0.55)
    # Soft lengthwise fur streaks.
    streak = noise.noise(Vector((p.x * 3.0, p.y * 40.0, p.z * 40.0)) / S)
    return mix(c, BROWN_DARK if streak < 0 else TAIL_LIGHT, abs(streak) * 0.18)


def flat(color):
    return lambda p, n, prim: color


# ---------------------------------------------------------------- build mesh

def body_prims():
    prims = []

    def e(center, radii, part, color, rot=None):
        prims.append(Prim(v(*center), Vector(radii) * S, rot or Matrix.Identity(3), part, color))

    e((-0.07, 0, 0.15), (0.085, 0.07, 0.075), "body", body_color, pitch_rot(0.15))
    e((0.02, 0, 0.148), (0.085, 0.066, 0.072), "body", body_color)
    e((0.10, 0, 0.152), (0.07, 0.06, 0.068), "body", body_color, pitch_rot(0.3))
    e((0.17, 0, 0.198), (0.05, 0.048, 0.052), "body", body_color, pitch_rot(0.7))
    e(HEAD_C, HEAD_R, "head", head_color, pitch_rot(-0.1))
    e((0.31, 0, 0.214), (0.038, 0.032, 0.028), "head", head_color, pitch_rot(-0.15))
    for s in (L, R):
        e((0.272, 0.03 * s, 0.212), (0.036, 0.03, 0.028), "head", head_color)
        # Fluffy cheek tuft trailing back.
        e((0.235, 0.04 * s, 0.205), (0.03, 0.022, 0.022), "head", head_color, pitch_rot(-0.4))
    # Tail: broad, flattened plume that widens past its base and softens at the tip.
    widths = [0.034, 0.05, 0.066, 0.072, 0.064]
    for i in range(5):
        a = Vector((TAIL_POINTS[i][0], 0, TAIL_POINTS[i][1]))
        b = Vector((TAIL_POINTS[i + 1][0], 0, TAIL_POINTS[i + 1][1]))
        rot, length = along(a, b)
        r = widths[i]
        e(tuple((a + b) * 0.5), (length * 0.65 + r * 0.7, r * 0.5, r), "tail", tail_color, rot)
    e((-0.52, 0, 0.345), (0.05, 0.026, 0.044), "tail", tail_color, pitch_rot(-0.4))
    for side, s in SIDES.items():
        a = [Vector(mirror(p, s)) for p in ARM]
        g = [Vector(mirror(p, s)) for p in LEG]
        for (p0, p1, r) in [(a[0], a[1], 0.028), (a[1], a[2], 0.019)]:
            rot, length = along(p0, p1)
            e(tuple((p0 + p1) * 0.5), (length * 0.5 + r * 0.6, r, r), "arm." + side, leg_color, rot)
        rot, length = along(a[2], a[3])
        e(tuple(a[2].lerp(a[3], 0.55)), (0.026, 0.018, 0.013), "arm." + side, leg_color, rot)
        # Haunch: the big rounded thigh that reads in every pose.
        e(tuple(g[0].lerp(g[1], 0.45) + Vector((-0.012, -0.008 * s, -0.005))), (0.068, 0.038, 0.062), "haunch." + side, leg_color, pitch_rot(-0.5))
        rot, length = along(g[1], g[2])
        e(tuple((g[1] + g[2]) * 0.5), (length * 0.5 + 0.012, 0.02, 0.02), "leg." + side, leg_color, rot)
        rot, length = along(g[2], g[3])
        e(tuple(g[2].lerp(g[3], 0.55)), (length * 0.55, 0.019, 0.013), "leg." + side, leg_color, rot)
    return prims


def surface(center, radii, rot, d):
    """Point and outward normal on an ellipsoid (design units) in direction d."""
    d = Vector(d).normalized()
    r = Vector(radii) * S
    point = v(*center) + rot @ Vector((d.x * r.x, d.y * r.y, d.z * r.z))
    normal = (rot @ Vector((d.x / r.x, d.y / r.y, d.z / r.z))).normalized()
    return point, normal


def facing(normal):
    """Rotation whose local +Y points along normal (thin axis of a flattened accent)."""
    return Vector((0, 1, 0)).rotation_difference(normal).to_matrix()


def accent_parts():
    """Crisp pieces kept out of the remesh: (center, radii, rot, color, bone, point)."""
    parts = []
    head_rot = pitch_rot(-0.1)
    for side, s in SIDES.items():
        # Big dark eyes in a cream ring, set into the side of the head.
        point, n = surface(HEAD_C, HEAD_R, head_rot, (0.55, 0.78 * s, 0.22))
        rot = facing(n * s) @ Matrix.Rotation(0.15, 3, "Y")
        parts.append((point - n * 0.004 * S, Vector((0.031, 0.012, 0.034)) * S, rot, CREAM, "head", 0))
        eye = point + n * 0.001 * S
        parts.append((eye, Vector((0.023, 0.011, 0.026)) * S, rot, EYE, "head", 0))
        up = Vector((0.4, 0, 1)).normalized()
        parts.append((eye + n * 0.009 * S + up * 0.011 * S, Vector((0.0065, 0.004, 0.0065)) * S, rot, WHITE, "head", 0))
        parts.append((eye + n * 0.009 * S - up * 0.01 * S, Vector((0.0028, 0.002, 0.0028)) * S, rot, WHITE, "head", 0))
        # Ears: thin teardrops facing forward-out, tilted back; pink inner face in front.
        face = Matrix.Rotation(0.75 * s, 3, "Z") @ Matrix.Rotation(-0.3, 3, "Y")
        ear, _ = surface(HEAD_C, HEAD_R, head_rot, (-0.15, 0.45 * s, 0.85))
        ear += Vector((0, 0, 0.012 * S))
        parts.append((ear, Vector((0.007, 0.021, 0.032)) * S, face, BROWN, "ear." + side, 0.55))
        parts.append((ear + face @ Vector((0.004 * S, 0, -0.002 * S)), Vector((0.004, 0.014, 0.022)) * S, face, PINK, "ear." + side, 0.55))
    nose, n = surface((0.31, 0, 0.214), (0.038, 0.032, 0.028), pitch_rot(-0.15), (1, 0, 0.35))
    parts.append((nose, Vector((0.009, 0.011, 0.007)) * S, Matrix.Identity(3), NOSE, "head", 0))
    return parts


def mesh_object(name, bm):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(obj)
    return obj


def evaluated_copy(obj, name):
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(obj.evaluated_get(depsgraph))
    mesh.name = name
    bpy.data.objects.remove(obj)
    out = bpy.data.objects.new(name, mesh)
    bpy.context.scene.collection.objects.link(out)
    return out


def build_body(prims):
    bm = bmesh.new()
    for p in prims:
        q = p.rot
        add_ellipsoid(bm, p.center, p.radii, q)
    obj = mesh_object("squirrel_raw", bm)
    remesh = obj.modifiers.new("remesh", "REMESH")
    remesh.mode = "VOXEL"
    remesh.voxel_size = VOXEL
    smooth = obj.modifiers.new("smooth", "LAPLACIANSMOOTH")
    smooth.lambda_factor = 1.0
    smooth.iterations = 12
    smooth.use_volume_preserve = True
    obj = evaluated_copy(obj, "squirrel_smooth")
    tris = sum(len(poly.vertices) - 2 for poly in obj.data.polygons)
    dec = obj.modifiers.new("decimate", "DECIMATE")
    dec.ratio = min(1.0, TARGET_TRIS / max(tris, 1))
    return evaluated_copy(obj, "squirrel_body")


def build_membrane():
    """Two-layer flank sheets, rows u (front->back) x v (body->edge)."""
    bm = bmesh.new()
    info = {}  # vert -> (side, u, v, top)
    U, V = 12, 5
    for side, s in SIDES.items():
        for top in (True, False):
            grid = []
            for i in range(U + 1):
                u = i / U
                row = []
                for j in range(V + 1):
                    w = j / V
                    inner = Vector((0.10 - 0.15 * u, 0.042 * s, 0.13 - 0.01 * u))
                    outer = Vector((0.10 - 0.15 * u, 0.052 * s, 0.10 - 0.005 * u))
                    # The free edge is scalloped inward between wrist and ankle.
                    p = inner.lerp(outer, w)
                    p.z += (0.0015 if top else -0.0015)
                    vert = bm.verts.new(v(*p))
                    info[vert] = (side, u, w, top)
                    row.append(vert)
                grid.append(row)
            for i in range(U):
                for j in range(V):
                    quad = [grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]]
                    if (s > 0) != top:
                        quad.reverse()
                    bm.faces.new(quad)
    bm.verts.index_update()
    infos = [info[vert] for vert in bm.verts]
    obj = mesh_object("membrane", bm)
    return obj, infos


def segment_distance(p, a, b):
    ab = b - a
    t = min(max((p - a).dot(ab) / ab.length_squared, 0.0), 1.0)
    return (p - (a + ab * t)).length


def build_squirrel(arm_obj):
    prims = body_prims()
    body = build_body(prims)
    mesh = body.data
    bone_seg = {name: (v(*h), v(*t)) for name, (h, t, _) in BONES.items()}

    colors = []
    weights = []
    sigma = 0.018 * S
    for vert in mesh.vertices:
        p, n = vert.co, vert.normal
        prim = min(prims, key=lambda pr: pr.field(p))
        colors.append(prim.color(p, n, prim))
        # The haunch leans on the hips so it stays rounded when the leg splays out.
        bias = {b: 1.6 if prim.part.startswith("haunch") and b.startswith("thigh") else 1.0 for b in PART_BONES[prim.part]}
        d = {b: segment_distance(p, *bone_seg[b]) * bias[b] for b in PART_BONES[prim.part]}
        dmin = min(d.values())
        w = sorted(((math.exp(-(dist - dmin) / sigma), b) for b, dist in d.items()), reverse=True)[:3]
        w = [(x, b) for x, b in w if x > 0.05]
        total = sum(x for x, _ in w)
        weights.append([(b, x / total) for x, b in w])

    # Accents join as rigid pieces. Data is keyed by BMVert, since BMesh may
    # reuse freed slots and new verts don't simply append.
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bm.verts.ensure_lookup_table()
    vcolor = {bm.verts[i]: c for i, c in enumerate(colors)}
    vweight = {bm.verts[i]: w for i, w in enumerate(weights)}
    for center, radii, rot, color, bone, point in accent_parts():
        for vert in add_ellipsoid(bm, center, radii, rot, point=point, segments=(16, 10)):
            vcolor[vert] = color
            vweight[vert] = [(bone, 1.0)]
    membrane, infos = build_membrane()
    new = []
    for vert, (side, u, w, top) in zip(membrane.data.vertices, infos):
        bv = bm.verts.new(vert.co)
        new.append(bv)
        edge = mix(CREAM, BROWN_DARK, smoothstep(0.75, 1.0, w) * 0.6)
        vcolor[bv] = fur(BROWN, Vector((u, w, 0)) * 0.1, Vector((0, 0, 1)), dark=0.1) if top else edge
        spine = [("chest", 1.0 - u), ("hips", u)]
        rim = [("membrane_front." + side, 1.0 - u), ("membrane_back." + side, u)]
        vweight[bv] = [(b, x * (1.0 - w)) for b, x in spine] + [(b, x * w) for b, x in rim]
    for poly in membrane.data.polygons:
        bm.faces.new([new[i] for i in poly.vertices])
    bpy.data.objects.remove(membrane)
    colors = [vcolor[vert] for vert in bm.verts]
    weights = [vweight[vert] for vert in bm.verts]
    bm.to_mesh(mesh)
    bm.free()

    for poly in mesh.polygons:
        poly.use_smooth = True
    attr = mesh.color_attributes.new("Col", "FLOAT_COLOR", "POINT")
    for i, c in enumerate(colors):
        # Stored as sRGB values: Godot linearises imported vertex colours itself.
        attr.data[i].color = (*c, 1.0)
    mesh.color_attributes.active_color_index = 0
    mesh.color_attributes.render_color_index = 0

    body.name = "squirrel"
    mesh.name = "squirrel"
    groups = {name: body.vertex_groups.new(name=name) for name in BONES if name != "root"}
    for i, ws in enumerate(weights):
        for b, x in ws:
            if x > 0.0:
                groups[b].add([i], x, "ADD")
    body.parent = arm_obj
    mod = body.modifiers.new("armature", "ARMATURE")
    mod.object = arm_obj
    return body


def build_armature():
    data = bpy.data.armatures.new("squirrel_rig")
    obj = bpy.data.objects.new("squirrel_rig", data)
    bpy.context.scene.collection.objects.link(obj)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    for name, (h, t, parent) in BONES.items():
        bone = data.edit_bones.new(name)
        bone.head, bone.tail = v(*h), v(*t)
        bone.use_deform = name != "root"
    for name, (h, t, parent) in BONES.items():
        if parent:
            bone = data.edit_bones[name]
            bone.parent = data.edit_bones[parent]
            bone.use_connect = Vector(BONES[parent][1]) == Vector(h)
    bpy.ops.object.mode_set(mode="OBJECT")
    for side in SIDES:
        for anchor, target in (("membrane_front", "arm_lower"), ("membrane_back", "shin")):
            con = obj.pose.bones["%s.%s" % (anchor, side)].constraints.new("COPY_LOCATION")
            con.name = "pin"
            con.target = obj
            con.subtarget = "%s.%s" % (target, side)
            con.head_tail = 1.0
            con.influence = 0.0
    for pb in obj.pose.bones:
        pb.rotation_mode = "QUATERNION"
    return obj


# ---------------------------------------------------------------- animation

def rest_rot(rig, name):
    return rig.data.bones[name].matrix_local.to_3x3()


def bone_quat(rig, name, pitch=0.0, abduct=0.0, yaw=0.0):
    """Rotation in rest-frame armature axes: pitch tips the bone's far end toward
    +X/+Z (nose up / leg forward), abduct swings it out to its own side, yaw turns
    it about Z. Converted into the bone's local frame."""
    side = 1.0
    if name.endswith(".R"):
        side = -1.0
        yaw = -yaw
    world = (Matrix.Rotation(yaw, 3, "Z") @ Matrix.Rotation(abduct * side, 3, "X")
             @ Matrix.Rotation(-pitch, 3, "Y"))
    m = rest_rot(rig, name)
    return (m.inverted() @ world @ m).to_quaternion()


def both(pose, name, **kw):
    for side in SIDES:
        pose["%s.%s" % (name, side)] = kw
    return pose


def tail_wave(pose, phase, amp, base, lag=0.12, rise=0.0):
    for i in range(1, 6):
        pose["tail%d" % i] = {"pitch": base[i - 1] + amp * math.sin(math.tau * (phase - lag * i)) + rise}


def run_poses():
    """Four key poses of the gallop (the sheet's RUN row), at frames 0, 4, 8, 12."""
    keys = []
    # p0 extended flight: front reaching, hind trailing, body long.
    p = {"root": {"z": 0.022, "pitch": 0.04}, "hips": {"pitch": -0.08}, "chest": {"pitch": 0.08},
         "neck": {"pitch": -0.02}, "head": {"pitch": -0.06}}
    both(p, "arm_upper", pitch=1.05)
    both(p, "arm_lower", pitch=0.35)
    both(p, "hand", pitch=-0.25)
    both(p, "thigh", pitch=-1.05)
    both(p, "shin", pitch=-0.35)
    both(p, "foot", pitch=-0.5)
    keys.append(p)
    # p1 front plant: body over the forepaws, hind legs swinging forward.
    p = {"root": {"z": 0.0, "pitch": -0.06}, "hips": {"pitch": 0.08}, "chest": {"pitch": -0.04},
         "neck": {"pitch": 0.04}, "head": {"pitch": 0.0}}
    both(p, "arm_upper", pitch=-0.15)
    both(p, "arm_lower", pitch=0.05)
    both(p, "hand", pitch=0.2)
    both(p, "thigh", pitch=0.35)
    both(p, "shin", pitch=-0.75)
    both(p, "foot", pitch=0.45)
    keys.append(p)
    # p2 gathered: back arched, hind feet planted ahead of the forepaws' tracks.
    p = {"root": {"z": -0.012, "pitch": -0.02}, "hips": {"pitch": 0.32}, "chest": {"pitch": -0.32},
         "neck": {"pitch": 0.08}, "head": {"pitch": -0.04}}
    both(p, "arm_upper", pitch=-0.95)
    both(p, "arm_lower", pitch=0.85)
    both(p, "hand", pitch=-0.9)
    both(p, "thigh", pitch=0.75)
    both(p, "shin", pitch=0.05)
    both(p, "foot", pitch=-0.75)
    keys.append(p)
    # p3 hind push: hind legs drive back, front legs fold forward to reach.
    p = {"root": {"z": 0.016, "pitch": 0.1}, "hips": {"pitch": 0.05}, "chest": {"pitch": -0.02},
         "neck": {"pitch": -0.04}, "head": {"pitch": -0.06}}
    both(p, "arm_upper", pitch=0.35)
    both(p, "arm_lower", pitch=1.05)
    both(p, "hand", pitch=-0.7)
    both(p, "thigh", pitch=-0.55)
    both(p, "shin", pitch=-0.25)
    both(p, "foot", pitch=-0.85)
    keys.append(p)
    for i, p in enumerate(keys):
        tail_wave(p, i / 4, 0.06, [0.2, 0.05, -0.05, -0.1, -0.15])
        both(p, "ear", pitch=0.15 + 0.08 * math.sin(math.tau * (i / 4 - 0.2)))
    return [(i * 4, p) for i, p in enumerate(keys)] + [(16, keys[0])]


def jump_poses():
    keys = []

    def pose(frame, root_z, root_pitch, hips, chest, neck, head, arm, hind, tail, ear=0.1):
        p = {"root": {"z": root_z, "pitch": root_pitch}, "hips": {"pitch": hips}, "chest": {"pitch": chest},
             "neck": {"pitch": neck}, "head": {"pitch": head}}
        for name, value in zip(("arm_upper", "arm_lower", "hand"), arm):
            both(p, name, pitch=value)
        for name, value in zip(("thigh", "shin", "foot"), hind):
            both(p, name, pitch=value)
        for i in range(1, 6):
            p["tail%d" % i] = {"pitch": tail[i - 1]}
        both(p, "ear", pitch=ear)
        keys.append((frame, p))

    # Ready (like the front-plant run pose).
    pose(0, 0.0, -0.04, 0.08, -0.04, 0.04, 0.0, (-0.15, 0.05, 0.2), (0.35, -0.75, 0.45), (-0.2, -0.05, -0.05, -0.08, -0.1))
    # Crouch: low, gathered, tail lifted for balance.
    pose(4, -0.035, -0.12, 0.3, -0.2, 0.2, 0.05, (-0.45, 0.5, -0.1), (0.95, -1.3, 0.55), (0.1, 0.1, 0.0, -0.05, -0.1), ear=0.25)
    # Launch: body tips up, hind legs straighten hard, forepaws lift and reach.
    pose(7, 0.0, 0.5, -0.05, 0.05, -0.2, -0.25, (0.9, 0.3, -0.4), (-1.15, -0.25, -0.9), (-0.45, -0.15, -0.1, -0.05, -0.05), ear=0.35)
    # Rise: legs tuck, tail sweeps up behind.
    pose(12, 0.0, 0.25, -0.12, 0.12, -0.12, -0.15, (0.6, 1.0, -0.6), (-0.6, -0.4, -0.6), (-0.15, 0.1, 0.12, 0.05, 0.0), ear=0.3)
    # Stretch at the peak: long body, forepaws ahead, hind feet trailing.
    pose(16, 0.0, 0.0, -0.08, 0.1, -0.02, -0.04, (1.0, 0.25, -0.2), (-1.0, -0.35, -0.6), (-0.25, 0.0, 0.05, 0.0, -0.05), ear=0.25)
    # Reach for the landing: nose down, forepaws extended, hind legs swing under.
    pose(20, 0.0, -0.22, 0.12, -0.05, 0.1, 0.12, (0.45, 0.1, 0.15), (0.45, -0.6, 0.2), (0.0, 0.08, 0.05, -0.02, -0.08), ear=0.15)
    # Land: squash onto the forepaws, back arched, tail flips up.
    pose(22, -0.03, -0.08, 0.32, -0.3, 0.12, 0.0, (-0.25, 0.25, 0.1), (0.8, -0.2, -0.6), (0.2, 0.15, 0.08, 0.0, -0.05), ear=0.05)
    # Recover to the ready pose so it blends into run.
    pose(24, 0.0, -0.04, 0.08, -0.04, 0.04, 0.0, (-0.15, 0.05, 0.2), (0.35, -0.75, 0.45), (-0.2, -0.05, -0.05, -0.08, -0.1))
    return keys


def idle_poses():
    keys = []
    for f in (0, 12, 24, 36, 48):
        ph = f / 48
        s = math.sin(math.tau * ph)
        p = {"root": {"z": 0.002 * s}, "hips": {"pitch": 0.04}, "chest": {"pitch": -0.02 + 0.03 * s},
             "neck": {"pitch": 0.05 - 0.02 * s}, "head": {"pitch": -0.04 + 0.03 * math.sin(math.tau * (ph - 0.2))}}
        both(p, "hand", pitch=0.1)
        both(p, "foot", pitch=0.05)
        both(p, "ear", pitch=0.1 + (0.12 if f == 36 else 0.0))
        tail_wave(p, ph, 0.05, [0.1, 0.05, 0.0, -0.05, -0.1], lag=0.08)
        keys.append((f, p))
    return keys


def glide_poses():
    keys = []
    for f in (0, 6, 12, 18, 24):
        ph = f / 24
        s = math.sin(math.tau * ph)
        c = math.cos(math.tau * ph)
        p = {"root": {"z": 0.01 * s, "pitch": 0.02 * c}, "hips": {"pitch": -0.04}, "chest": {"pitch": 0.06 - 0.02 * s},
             "neck": {"pitch": -0.05}, "head": {"pitch": 0.0 + 0.04 * c}}
        # Forelegs spread out and forward, hind legs out and back: the membrane goes taut.
        both(p, "arm_upper", pitch=0.7, abduct=1.05 + 0.06 * s)
        both(p, "arm_lower", pitch=0.15, abduct=0.2)
        both(p, "hand", pitch=0.1, abduct=0.3)
        both(p, "thigh", pitch=-0.8, abduct=0.95 - 0.05 * s)
        both(p, "shin", pitch=-0.25, abduct=0.15)
        both(p, "foot", pitch=-0.6, abduct=0.2)
        both(p, "ear", pitch=0.45)
        tail_wave(p, ph, 0.05, [0.75, 0.15, -0.05, -0.1, -0.1])
        for side in SIDES:
            for anchor in ("membrane_front", "membrane_back"):
                p["%s.%s" % (anchor, side)] = {"pin": 1.0}
        keys.append((f, p))
    return keys


def apply_pose(rig, pose):
    for pb in rig.pose.bones:
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
        for con in pb.constraints:
            con.influence = 0.0
    for name, values in pose.items():
        pb = rig.pose.bones[name]
        if "pin" in values:
            pb.constraints["pin"].influence = values["pin"]
            continue
        pb.rotation_quaternion = bone_quat(rig, name, values.get("pitch", 0.0), values.get("abduct", 0.0), values.get("yaw", 0.0))
        if "z" in values:
            pb.location = rest_rot(rig, name).inverted() @ Vector((0, 0, values["z"] * S))


def make_action(rig, name, keys, loop):
    rig.animation_data_create()
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    rig.animation_data.action = action
    previous = {}
    for frame, pose in keys:
        apply_pose(rig, pose)
        for pb in rig.pose.bones:
            q = pb.rotation_quaternion.copy()
            if pb.name in previous and previous[pb.name].dot(q) < 0:
                q.negate()
                pb.rotation_quaternion = q
            previous[pb.name] = q
            pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
            if pb.name == "root":
                pb.keyframe_insert("location", frame=frame, group=pb.name)
            for con in pb.constraints:
                con.keyframe_insert("influence", frame=frame)
    action.frame_range = (keys[0][0], keys[-1][0])
    action.use_frame_range = True
    action.use_cyclic = loop
    if loop:
        from bpy_extras import anim_utils
        bag = anim_utils.action_get_channelbag_for_slot(action, rig.animation_data.action_slot)
        for fc in bag.fcurves:
            fc.modifiers.new("CYCLES")
            fc.update()
    track = rig.animation_data.nla_tracks.new()
    track.name = name
    strip = track.strips.new(name, int(keys[0][0]), action)
    track.mute = True
    rig.animation_data.action = None
    return action


# ---------------------------------------------------------------- preview

def preview_material(obj):
    mat = bpy.data.materials.new("squirrel_preview")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    bsdf = nodes["Principled BSDF"]
    attr = nodes.new("ShaderNodeVertexColor")
    attr.layer_name = "Col"
    gamma = nodes.new("ShaderNodeGamma")  # sRGB-valued colours -> linear for Blender's shading
    gamma.inputs[1].default_value = 2.2
    mat.node_tree.links.new(attr.outputs["Color"], gamma.inputs["Color"])
    mat.node_tree.links.new(gamma.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.85
    obj.data.materials.append(mat)


def render_preview(rig):
    import numpy as np
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x, scene.render.resolution_y = 420, 300
    scene.render.film_transparent = False
    world = bpy.data.worlds.new("preview")
    world.use_nodes = True
    world.node_tree.nodes["Background"].inputs[0].default_value = (0.32, 0.33, 0.35, 1)
    world.node_tree.nodes["Background"].inputs[1].default_value = 0.9
    scene.world = world
    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    sun.data.energy = 3.5
    sun.rotation_euler = (math.radians(50), math.radians(-20), math.radians(-30))
    scene.collection.objects.link(sun)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 2.1
    scene.collection.objects.link(cam)
    scene.camera = cam
    rows = [("run", [0, 2, 4, 6, 8, 10, 12, 14], (90, 0, 0)),
            ("jump", [0, 4, 7, 12, 16, 20, 22, 24], (90, 0, 0)),
            ("glide", [0, 6, 12, 18, 0, 6, 12, 18], [(125, 0, -20)] * 4 + [(90, 0, 0)] * 4)]
    sheet = None
    tmp = os.path.join(bpy.app.tempdir or "/tmp", "squirrel_frame.png")
    for r, (name, frames, rots) in enumerate(rows):
        rig.animation_data.action = bpy.data.actions[name]
        for c, f in enumerate(frames):
            rot = rots[c] if isinstance(rots, list) else rots
            scene.frame_set(f)
            e = [math.radians(a) for a in rot]
            cam.rotation_euler = e
            cam.location = Matrix.Rotation(e[2], 3, "Z") @ Matrix.Rotation(e[0], 3, "X") @ Vector((0, 0, 3.0)) + Vector((-0.25, 0, 0.32))
            scene.render.filepath = tmp
            bpy.ops.render.render(write_still=True)
            img = bpy.data.images.load(tmp)
            px = np.array(img.pixels[:]).reshape(img.size[1], img.size[0], 4)
            bpy.data.images.remove(img)
            if sheet is None:
                sheet = np.zeros((len(rows) * px.shape[0], 8 * px.shape[1], 4))
            h, w = px.shape[:2]
            sheet[(len(rows) - 1 - r) * h:(len(rows) - r) * h, c * w:(c + 1) * w] = px
    out = bpy.data.images.new("sheet", sheet.shape[1], sheet.shape[0], alpha=True)
    out.pixels = sheet.ravel()
    out.filepath_raw = PREVIEW_PATH
    out.file_format = "PNG"
    out.save()
    rig.animation_data.action = None
    print("SQUIRREL PREVIEW ->", PREVIEW_PATH)


# ---------------------------------------------------------------- main

def build():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.fps = FPS
    rig = build_armature()
    body = build_squirrel(rig)
    preview_material(body)
    for name, keys, loop in (("run", run_poses(), True), ("jump", jump_poses(), False), ("glide", glide_poses(), True),
                             ("idle", idle_poses(), True)):
        make_action(rig, name, keys, loop)
    for pb in rig.pose.bones:
        pb.rotation_quaternion = Quaternion()
        pb.location = Vector()
    scene.frame_start, scene.frame_end = 0, 24

    os.makedirs(os.path.dirname(BLEND_PATH), exist_ok=True)
    os.makedirs(os.path.dirname(GLB_PATH), exist_ok=True)
    if "--preview" in sys.argv:
        render_preview(rig)
    for track in rig.animation_data.nla_tracks:
        track.mute = True
    rig.animation_data.action = bpy.data.actions["run"]
    bpy.ops.wm.save_as_mainfile(filepath=BLEND_PATH)

    rig.animation_data.action = None
    bpy.ops.object.select_all(action="DESELECT")
    rig.select_set(True)
    body.select_set(True)
    bpy.ops.export_scene.gltf(filepath=GLB_PATH, export_format="GLB", use_selection=True,
        export_vertex_color="ACTIVE", export_all_vertex_colors=False, export_normals=True,
        export_materials="NONE", export_yup=True, export_animations=True,
        export_animation_mode="ACTIONS", export_force_sampling=True)
    tris = sum(len(p.vertices) - 2 for p in body.data.polygons)
    print("SQUIRREL: %d verts, %d tris, %d bones -> %s" % (len(body.data.vertices), tris, len(rig.data.bones), GLB_PATH))


build()
