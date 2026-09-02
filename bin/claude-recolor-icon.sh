#!/bin/bash
# claude-recolor-icon.sh -- regenerate a coloured Claude icon master.
#
#   claude-recolor-icon.sh <hue-degrees> <output.icns>
#
#   blue  (Enterprise) = 212      green (Personal) = 142
#   others: red 0 · orange 30 · yellow 55 · teal 175 · purple 275 · pink 320
#
# Rotates the stock coral icon's hue in HSV, so the starburst, grain texture,
# inner shading and drop shadow all survive -- only hue moves. The tile is then
# deepened slightly (weighted by saturation) so the near-white starburst keeps
# its contrast at small sizes.
#
# Requires python3 with numpy + Pillow (the miniconda python3 on this Mac has both).

set -euo pipefail

HUE="${1:-}"; OUT="${2:-}"
[ -n "$HUE" ] && [ -n "$OUT" ] || { sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

SRC="/Applications/Claude.app/Contents/Resources/electron.icns"
[ -f "$SRC" ] || { echo "error: $SRC not found" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
iconutil --convert iconset --output "$TMP/src.iconset" "$SRC"

python3 - "$TMP" "$HUE" <<'PY'
import sys, numpy as np
from PIL import Image
TMP, HUE = sys.argv[1], float(sys.argv[2])/360.0

m = Image.open(f"{TMP}/src.iconset/icon_512x512@2x.png").convert("RGBA")
a = np.asarray(m).astype(np.float32)/255.0
rgb, al = a[..., :3], a[..., 3:]
mx, mn = rgb.max(-1), rgb.min(-1); diff = mx - mn

h = np.zeros_like(mx); nz = diff > 1e-6
r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
i = (mx == r) & nz; h[i] = ((g[i]-b[i])/diff[i]) % 6.0
i = (mx == g) & nz; h[i] = ((b[i]-r[i])/diff[i]) + 2.0
i = (mx == b) & nz; h[i] = ((r[i]-g[i])/diff[i]) + 4.0
h = (h/6.0) % 1.0
s = np.where(mx > 1e-6, diff/np.maximum(mx, 1e-6), 0.0); v = mx

src_hue = float(np.median(h[s > 0.25]))          # the coral tile
h = (h + (HUE - src_hue)) % 1.0

h6 = h*6.0; k = np.floor(h6).astype(np.int32) % 6; f = h6 - np.floor(h6)
p, q, t = v*(1-s), v*(1-s*f), v*(1-s*(1-f))
out = np.zeros_like(rgb)
for idx, (cr, cg, cb) in enumerate([(v,t,p),(q,v,p),(p,v,t),(p,q,v),(t,p,v),(v,p,q)]):
    mk = k == idx
    out[...,0][mk] = cr[mk]; out[...,1][mk] = cg[mk]; out[...,2][mk] = cb[mk]

w = np.clip((s-0.12)/0.25, 0, 1)[..., None]      # tile only; starburst untouched
out = out*(1 - 0.16*w)
grey = out.mean(-1, keepdims=True)
out = np.clip(grey + (out-grey)*(1 + 0.35*w), 0, 1)

img = Image.fromarray((np.concatenate([out, al], -1)*255).round().astype(np.uint8), "RGBA")
import os
os.makedirs(f"{TMP}/out.iconset", exist_ok=True)
for size, names in [(16,["icon_16x16.png"]),(32,["icon_16x16@2x.png","icon_32x32.png"]),
                    (64,["icon_32x32@2x.png"]),(128,["icon_128x128.png"]),
                    (256,["icon_128x128@2x.png","icon_256x256.png"]),
                    (512,["icon_256x256@2x.png","icon_512x512.png"]),
                    (1024,["icon_512x512@2x.png"])]:
    im = img if size == img.width else img.resize((size, size), Image.LANCZOS)
    for n in names: im.save(f"{TMP}/out.iconset/{n}")
print(f"  coral {src_hue*360:.1f} deg -> {HUE*360:.1f} deg")
PY

mkdir -p "$(dirname "$OUT")"
iconutil --convert icns --output "$OUT" "$TMP/out.iconset"
echo "  wrote $OUT ($(du -h "$OUT" | cut -f1))"
echo "  install it, then rebuild:  claude-apps-refresh.sh"
