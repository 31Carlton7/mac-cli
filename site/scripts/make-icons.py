#!/usr/bin/env python3
"""Render every favicon/app-icon size from one source geometry.

    python3 site/scripts/make-icons.py

Writes into site/assets/:
    favicon.ico          16/32/48, for legacy browsers and search results
    favicon-32.png       PNG fallback for browsers that skip the SVG
    icon-192.png         web app manifest
    icon-512.png         web app manifest / install prompt
    apple-touch-icon.png 180x180, full-bleed (iOS applies its own mask)

favicon.svg is authored by hand and is the shape of record; the geometry here
mirrors it on a 64-unit grid. The look follows the mcpmanager.space icon: a
charcoal squircle with a subtle top-to-bottom gradient, and a thin white
line-art glyph with round caps.
"""

import io
import os
import struct

from PIL import Image, ImageDraw

SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(SITE, "assets")

INK = (255, 255, 255, 255)
TOP = (66, 67, 70)       # tile gradient, top
BOTTOM = (28, 28, 31)    # tile gradient, bottom
RADIUS = 14.3            # on the 64 grid, ~22% — matches the reference icon
STROKE = 3.6
SS = 4                   # supersample factor


def tile(n, rounded=True):
    """A vertical charcoal gradient, clipped to a rounded square."""
    grad = Image.new("RGB", (1, n))
    gd = grad.load()
    for y in range(n):
        t = y / max(1, n - 1)
        gd[0, y] = tuple(round(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3))
    grad = grad.resize((n, n))

    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, n - 1, n - 1], radius=(RADIUS / 64 * n) if rounded else 0, fill=255
    )
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    out.paste(grad, (0, 0), mask)
    return out


def optical_stroke(px):
    """Small favicons need a heavier stroke or the line greys out: at 16px a
    3.6/64 stroke lands under one device pixel. Full weight from 64px up."""
    if px >= 64:
        return 1.0
    return 1.0 + (64 - px) / 48 * 0.45


def render(px, rounded=True, inset=0.0):
    """Draw the mark at `px`. `inset` pulls the glyph toward the centre for
    full-bleed icons, where iOS crops the corners itself."""
    n = px * SS
    img = tile(n, rounded)
    d = ImageDraw.Draw(img)
    u = n / 64.0

    def p(x, y):
        return ((32 + (x - 32) * (1 - inset)) * u,
                (32 + (y - 32) * (1 - inset)) * u)

    w = STROKE * optical_stroke(px) * u * (1 - inset)

    def stroke(points):
        d.line(points, fill=INK, width=max(1, round(w)), joint="curve")
        for cx, cy in points:                       # round the caps and joints
            d.ellipse([cx - w / 2, cy - w / 2, cx + w / 2, cy + w / 2], fill=INK)

    stroke([p(12, 20), p(24.5, 32), p(12, 44)])     # chevron
    stroke([p(33, 44), p(50, 44)])                  # underscore

    return img.resize((px, px), Image.LANCZOS)


def save_ico(images, path):
    """Write a multi-size .ico with PNG-compressed entries (Vista+, which every
    current browser reads), one distinct image per size."""
    blobs = []
    for im in images:
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        blobs.append(buf.getvalue())

    offset = 6 + 16 * len(blobs)
    header = struct.pack("<HHH", 0, 1, len(blobs))
    entries, payload = b"", b""
    for im, blob in zip(images, blobs):
        w, h = im.size
        entries += struct.pack(
            "<BBBBHHII",
            w if w < 256 else 0, h if h < 256 else 0,
            0, 0, 1, 32, len(blob), offset,
        )
        payload += blob
        offset += len(blob)

    with open(path, "wb") as fh:
        fh.write(header + entries + payload)


def main():
    render(512).save(os.path.join(ASSETS, "icon-512.png"))
    render(192).save(os.path.join(ASSETS, "icon-192.png"))
    render(32).save(os.path.join(ASSETS, "favicon-32.png"))

    # iOS masks the corners itself, so ship a square tile with the glyph inset.
    render(180, rounded=False, inset=0.10).convert("RGB").save(
        os.path.join(ASSETS, "apple-touch-icon.png"))

    # Each .ico size is drawn at its own weight rather than downsampled from one
    # render, so the 16px entry keeps a visible stroke. Pillow's ICO writer
    # resizes a single base image, so the container is packed by hand.
    save_ico([render(s) for s in (16, 32, 48)],
             os.path.join(ASSETS, "favicon.ico"))

    for name in ("favicon.ico", "favicon-32.png", "icon-192.png",
                 "icon-512.png", "apple-touch-icon.png"):
        path = os.path.join(ASSETS, name)
        print(f"saved {name}  ({os.path.getsize(path):,} bytes)")


if __name__ == "__main__":
    main()
