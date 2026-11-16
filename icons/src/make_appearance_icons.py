# Builds the dark and tinted Home Screen icons (iOS 18+, issue #47) from
# icons/AppIcon1024.png: the white folder, ring and lock are lifted off the
# original, the teal badge is redrawn as a disk, and both go on a new
# background. Run: python3 icons/src/make_appearance_icons.py (needs Pillow, numpy).
import os
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = os.path.dirname(HERE)
SIZE = 1024
CENTER, BADGE_R = 717.0, 160.5   # badge disk under the white ring (inner radius 159)

src = np.asarray(Image.open(os.path.join(ICONS, "AppIcon1024.png")).convert("RGB")).astype(np.float64)
white = np.clip((src.min(axis=-1) - 60.0) / 180.0, 0.0, 1.0)[..., None]

yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float64) + 0.5
dist = np.hypot(xx - CENTER, yy - CENTER)
badge = np.clip(BADGE_R - dist + 0.5, 0.0, 1.0)[..., None]

def gradient(top_left, bottom_right):
    t = ((xx + yy) / (2.0 * SIZE))[..., None]
    return np.array(top_left, float) * (1 - t) + np.array(bottom_right, float) * t

def compose(background, badge_color, glyph_color):
    out = background
    out = out * (1 - badge) + np.array(badge_color, float) * badge
    out = out * (1 - white) + np.array(glyph_color, float) * white
    return Image.fromarray(np.clip(out + 0.5, 0, 255).astype(np.uint8), "RGB")

# Dark: the new design's night backdrop, the badge keeps its teal.
compose(gradient((8, 11, 24), (14, 24, 46)), (13, 158, 168), (238, 242, 248)).save(
    os.path.join(ICONS, "AppIcon1024-dark.png"))
# Tinted: grayscale on black; iOS colors it by brightness.
compose(np.zeros((SIZE, SIZE, 3)), (120, 120, 120), (255, 255, 255)).convert("L").save(
    os.path.join(ICONS, "AppIcon1024-tinted.png"))
