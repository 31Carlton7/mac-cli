#!/usr/bin/env python3
"""Render site/assets/og.png — the social preview card.

Uses the landing page's own typefaces (Geist / Geist Mono) and the real macOS
app icons, so the card and the page stay in visual sync.

    python3 site/scripts/make-og.py

Needs Pillow, and the Geist font files. Point GEIST_FONTS at a directory
containing geist-sans/ and geist-mono/ if they aren't found automatically.
"""

import glob
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

W, H = 2400, 1260
INK = (245, 245, 247)   # --ink on the page
DIM = (110, 110, 115)   # --dim on the page

SITE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(SITE, "assets", "og.png")

# Every app mac drives, in the order the site lists them.
APPS = [
    ("Calendar", "/System/Applications/Calendar.app"),
    ("Reminders", "/System/Applications/Reminders.app"),
    ("Contacts", "/System/Applications/Contacts.app"),
    ("Mail", "/System/Applications/Mail.app"),
    ("Messages", "/System/Applications/Messages.app"),
    ("Notes", "/System/Applications/Notes.app"),
    ("Music", "/System/Applications/Music.app"),
    ("TV", "/System/Applications/TV.app"),
    ("Shortcuts", "/System/Applications/Shortcuts.app"),
    ("FaceTime", "/System/Applications/FaceTime.app"),
]


def find_geist():
    roots = []
    if os.environ.get("GEIST_FONTS"):
        roots.append(os.environ["GEIST_FONTS"])
    roots += glob.glob(os.path.expanduser("~/.bun/install/cache/geist@*/dist/fonts"))
    roots += glob.glob(os.path.join(SITE, "node_modules/geist/dist/fonts"))
    for root in roots:
        medium = os.path.join(root, "geist-sans", "Geist-Medium.ttf")
        if os.path.exists(medium):
            return root
    sys.exit(
        "Geist fonts not found. Install with `bun add geist` (or `npm i geist`), "
        "or set GEIST_FONTS to a directory containing geist-sans/ and geist-mono/."
    )


def icon_png(app_path, out_path, px=512):
    """Export an app's .icns to a PNG at `px`."""
    icns = sorted(glob.glob(os.path.join(app_path, "Contents/Resources/*.icns")))
    if not icns:
        sys.exit(f"No .icns found in {app_path}")
    subprocess.run(
        ["sips", "-s", "format", "png", "-Z", str(px), icns[0], "--out", out_path],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return out_path


def chevron(w, h, stroke, fill, ss=8):
    """A round-capped chevron, supersampled so its diagonals stay smooth.

    Drawn rather than typed: Geist Mono has no glyph for U+276F.
    """
    pad = stroke
    tile = Image.new("RGBA", (int((w + pad * 2) * ss), int((h + pad * 2) * ss)), (0, 0, 0, 0))
    td = ImageDraw.Draw(tile)
    pts = [(pad * ss, pad * ss),
           ((pad + w) * ss, (pad + h / 2) * ss),
           (pad * ss, (pad + h) * ss)]
    td.line(pts, fill=fill, width=int(stroke * ss), joint="curve")
    r = stroke * ss / 2
    for px, py in pts:
        td.ellipse([px - r, py - r, px + r, py + r], fill=fill)
    return tile.resize((int(w + pad * 2), int(h + pad * 2)), Image.LANCZOS)


def main():
    geist = find_geist()
    f_h1 = ImageFont.truetype(f"{geist}/geist-sans/Geist-Medium.ttf", 122)
    f_sub = ImageFont.truetype(f"{geist}/geist-sans/Geist-Regular.ttf", 46)
    f_prompt = ImageFont.truetype(f"{geist}/geist-mono/GeistMono-Regular.ttf", 46)

    img = Image.new("RGB", (W, H), (0, 0, 0))
    d = ImageDraw.Draw(img)

    def tracked_width(text, font, em):
        track = em * font.size
        return sum(d.textlength(c, font=font) for c in text) + track * (len(text) - 1)

    def draw_centered(text, font, y, fill, em=0.0):
        """Centered text with per-character letter-spacing, matching the page's CSS."""
        track = em * font.size
        x = (W - tracked_width(text, font, em)) / 2
        for ch in text:
            d.text((x, y), ch, font=font, fill=fill)
            x += d.textlength(ch, font=font) + track

    with tempfile.TemporaryDirectory() as tmp:
        size, gap = 150, 40
        x = (W - (len(APPS) * size + (len(APPS) - 1) * gap)) // 2
        for name, path in APPS:
            png = icon_png(path, os.path.join(tmp, f"{name}.png"))
            ic = Image.open(png).convert("RGBA").resize((size, size), Image.LANCZOS)
            img.paste(ic, (x, 268), ic)
            x += size + gap

    # prompt
    fs = f_prompt.size
    label = "mac"
    text_w = d.textlength(label, font=f_prompt)
    chev_w, chev_h, chev_gap, stroke = fs * 0.30, fs * 0.54, fs * 0.34, fs * 0.105
    x = (W - (chev_w + chev_gap + text_w)) / 2
    tile = chevron(chev_w, chev_h, stroke, DIM)
    img.paste(tile, (round(x - stroke), round(552 - tile.height / 2)), tile)
    d.text((x + chev_w + chev_gap, 552), label, font=f_prompt, fill=DIM, anchor="lm")

    # headline — -0.035em tracking mirrors the h1 on the landing page
    draw_centered("Your Mac’s apps,", f_h1, 645, INK, em=-0.035)
    draw_centered("on the command line.", f_h1, 790, INK, em=-0.035)

    draw_centered("An agent-friendly CLI · --json everywhere · free and MIT licensed",
                  f_sub, 1010, DIM)

    img.save(OUT)
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
