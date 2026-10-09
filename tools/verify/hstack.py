#!/usr/bin/env python3
"""hstack.py out.png height frame1.png frame2.png ...  -> horizontal strip scaled to `height`."""
import sys
from PIL import Image
out, height, files = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
ims = []
for f in files:
    im = Image.open(f).convert("RGB")
    w = max(1, round(im.size[0] * height / im.size[1]))
    ims.append(im.resize((w, height)))
gap = 6
strip = Image.new("RGB", (sum(i.size[0] for i in ims) + gap * (len(ims) - 1), height), (20, 20, 20))
x = 0
for i in ims:
    strip.paste(i, (x, 0)); x += i.size[0] + gap
strip.save(out)
print("wrote", out, strip.size)
