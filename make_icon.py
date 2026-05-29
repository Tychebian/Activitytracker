#!/usr/bin/env python3
"""
Generate AppIcon.icns for ActivityTracker.
Design: 4×4 time-slot grid, flat forest-green palette.
"""
from PIL import Image, ImageDraw
import os, subprocess, shutil

OUT_ICNS   = "/Users/jingran/activity_tracker/swift_app/Resources/AppIcon.icns"
ICONSET    = "/tmp/ActivityTracker.iconset"

# ── Palette ──────────────────────────────────────────────────────────────────
BG    = (16,  78,  43, 255)   # deep forest
EMPTY = (11,  52,  29, 255)   # dark pocket (unfilled slot)
C1    = (46, 204, 113, 255)   # vivid emerald
C2    = (39, 174,  96, 255)   # medium green
C3    = (113, 224, 168, 255)  # pale mint

# ── 4×4 grid pattern ─────────────────────────────────────────────────────────
# Each row = one "block" of the day; empty = unrecorded slot
GRID = [
    [C1,    C3,    C2,    C1   ],
    [C2,    C1,    C3,    EMPTY],
    [C3,    C2,    C1,    C2   ],
    [EMPTY, C1,    C2,    C3   ],
]

def draw_icon(size: int) -> Image.Image:
    img  = Image.new("RGBA", (size, size), BG)
    draw = ImageDraw.Draw(img)

    cols = rows = 4
    # Grid occupies ~64 % of width, centred
    grid_px  = int(size * 0.64)
    gap      = max(2, int(size * 0.024))
    cell     = (grid_px - gap * (cols - 1)) // cols
    total_w  = cols * cell + (cols - 1) * gap
    total_h  = rows * cell + (rows - 1) * gap
    ox       = (size - total_w) // 2
    oy       = (size - total_h) // 2
    radius   = max(1, cell // 6)

    for r, row in enumerate(GRID):
        for c, color in enumerate(row):
            x = ox + c * (cell + gap)
            y = oy + r * (cell + gap)
            draw.rounded_rectangle(
                [x, y, x + cell - 1, y + cell - 1],
                radius=radius, fill=color,
            )
            # Thin highlight on top edge (flat-design lift)
            if color != EMPTY:
                hi = (*color[:3], 70)          # translucent white-ish
                draw.rounded_rectangle(
                    [x, y, x + cell - 1, y + max(2, cell // 10)],
                    radius=radius,
                    fill=(min(color[0]+120,255),
                          min(color[1]+120,255),
                          min(color[2]+120,255), 55),
                )
    return img

SIZES = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png",1024),
]

# Generate master at 1024, downsample the rest
print("Drawing master 1024×1024 …")
master = draw_icon(1024)
master.save("/tmp/icon_preview_1024.png")
print("  preview saved → /tmp/icon_preview_1024.png")

os.makedirs(ICONSET, exist_ok=True)
for fname, sz in SIZES:
    img = master if sz == 1024 else master.resize((sz, sz), Image.LANCZOS)
    img.save(os.path.join(ICONSET, fname))
    print(f"  {sz:>4}px  →  {fname}")

print(f"\nPacking iconset …")
os.makedirs(os.path.dirname(OUT_ICNS), exist_ok=True)
subprocess.run(["iconutil", "-c", "icns", ICONSET, "-o", OUT_ICNS], check=True)
shutil.rmtree(ICONSET)
print(f"✓  {OUT_ICNS}")
