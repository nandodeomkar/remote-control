"""Remote Control brand-asset generator (quick 260716-ns1).

Draws the LOCKED "Concept A - pointer" mark and emits every logo asset:
dark rounded-square tile #0E0F12 with a subtle #2A303C border and a bold
blue #3B82F6 cursor-arrow glyph (classic arrow with click-tail), plus a
white arrow-only tray tint mask.

This script is the single source of truth for all branding rasters -- no
binary-only assets exist without a generator. Re-running it regenerates
every file byte-identically (Pillow writes no timestamp chunks).

Requires: Python 3.12 + Pillow 12.x (confirmed toolchain, no alternatives).

Outputs:
  server/server-windows/assets/icon/icon_{16,24,32,48,64,128,256}.png
  server/server-windows/assets/icon/icon.ico          (multi-size, crisp frames)
  server/server-windows/assets/icon/tray_arrow_32.png (white tint mask, RGBA)
  app/remote_control/android/app/src/main/res/mipmap-*/ic_launcher.png
"""

from pathlib import Path

from PIL import Image, ImageDraw

# ── Locked design constants (Concept A geometry, 140-unit reference tile) ──

REF = 140.0
TILE_FILL = (14, 15, 18, 255)      # #0E0F12 dark tile
TILE_BORDER = (42, 48, 60, 255)    # #2A303C subtle border
BORDER_W = 3.0                     # border width in REF units
CORNER_R = 28.0                    # corner radius in REF units (20% of tile)
ARROW = [(48, 36), (48, 108), (66, 92), (78, 118), (90, 112), (78, 87), (100, 85)]
ARROW_FILL = (59, 130, 246, 255)   # #3B82F6 bold blue

SS = 4  # supersample factor

ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]
ANDROID_DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}

REPO_ROOT = Path(__file__).resolve().parents[1]
ICON_DIR = REPO_ROOT / "server" / "server-windows" / "assets" / "icon"
ANDROID_RES = REPO_ROOT / "app" / "remote_control" / "android" / "app" / "src" / "main" / "res"


def render_tile(size: int) -> Image.Image:
    """Full brand tile (rounded dark square + border + blue arrow) at `size` px.

    Rendered at 4x then LANCZOS-downscaled for crisp antialiased edges.
    """
    w = size * SS
    k = w / REF
    img = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    draw.rounded_rectangle(
        [0, 0, w - 1, w - 1],
        radius=CORNER_R * k,
        fill=TILE_FILL,
        outline=TILE_BORDER,
        width=max(1, round(BORDER_W * k)),
    )
    draw.polygon([(x * k, y * k) for (x, y) in ARROW], fill=ARROW_FILL)
    return img.resize((size, size), Image.Resampling.LANCZOS)


def render_tray_glyph(size: int = 32) -> Image.Image:
    """Arrow ONLY, white on transparent, centered -- the tray tint mask.

    A dark tile would vanish on the dark taskbar; the white glyph's RGB is
    replaced per tray state at runtime while its antialiased alpha is kept.
    Glyph is scaled uniformly so its height fills 82% of the canvas.
    """
    w = size * SS
    # Arrow bbox in REF space: x in [48, 100] (w=52), y in [36, 118] (h=82).
    bw, bh = 52.0, 82.0
    s = (w * 0.82) / bh
    ox = (w - bw * s) / 2.0
    oy = (w - bh * s) / 2.0
    img = Image.new("RGBA", (w, w), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    pts = [((x - 48.0) * s + ox, (y - 36.0) * s + oy) for (x, y) in ARROW]
    draw.polygon(pts, fill=(255, 255, 255, 255))
    return img.resize((size, size), Image.Resampling.LANCZOS)


def main() -> None:
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    emitted: list[tuple[Path, int]] = []  # (path, expected square size)

    # 1. Tile PNGs at every ICO size.
    tiles = {s: render_tile(s) for s in ICO_SIZES}
    for s in ICO_SIZES:
        p = ICON_DIR / f"icon_{s}.png"
        tiles[s].save(p, format="PNG")
        emitted.append((p, s))

    # 2. Multi-size ICO: each frame rendered independently at its own
    #    supersample (do NOT let PIL auto-downscale from 256 -- small sizes
    #    would blur). append_images supplies exact-size frames (Pillow >= 9.1).
    ico_path = ICON_DIR / "icon.ico"
    tiles[256].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in ICO_SIZES],
        append_images=[tiles[s] for s in ICO_SIZES if s != 256],
    )

    # 3. Tray tint mask.
    tray_path = ICON_DIR / "tray_arrow_32.png"
    render_tray_glyph(32).save(tray_path, format="PNG")
    emitted.append((tray_path, 32))

    # 4. Android launcher PNGs (no adaptive-icon XML exists; overwrite is
    #    fully effective).
    for density, px in ANDROID_DENSITIES.items():
        p = ANDROID_RES / f"mipmap-{density}" / "ic_launcher.png"
        if not p.parent.is_dir():
            raise SystemExit(f"FAIL: missing Android res dir {p.parent}")
        render_tile(px).save(p, format="PNG")
        emitted.append((p, px))

    # ── Self-verification (assert, not print-and-hope) ──
    for p, expected in emitted:
        with Image.open(p) as img:
            assert img.size == (expected, expected), f"{p}: size {img.size} != {expected}"
            assert img.mode == "RGBA", f"{p}: mode {img.mode} != RGBA"
        print(f"OK  {p.relative_to(REPO_ROOT)}  {expected}x{expected} RGBA")
    assert ico_path.is_file() and ico_path.stat().st_size > 0, "icon.ico missing/empty"
    print(f"OK  {ico_path.relative_to(REPO_ROOT)}  {len(ICO_SIZES)} frames, "
          f"{ico_path.stat().st_size} bytes")
    print(f"DONE: {len(emitted) + 1} assets emitted")


if __name__ == "__main__":
    main()
