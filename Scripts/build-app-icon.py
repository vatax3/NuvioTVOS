"""Build the tvOS parallax icon from the brand mark.

The old icon dropped the 1080x1080 mark PNG — background and all, no alpha — into a 400x240
layer, so the home screen drew a dark square floating inside the rounded app bubble. A layered
tvOS icon is three full-bleed planes that move against each other; this builds those.
"""
from PIL import Image, ImageFilter, ImageDraw
import math, pathlib

SCRATCH = pathlib.Path("/private/tmp/claude-501/-Users-valentin-NuvioTVOS/95aab95f-0ca3-4edb-bb00-8485f0f42be3/scratchpad")
MARK = Image.open(SCRATCH / "mark_alpha.png")
NAVY = (13, 16, 30)
CYAN = (56, 209, 226)
MAGENTA = (198, 84, 220)

def radial(size, centre, radius, colour, peak):
    """One soft brand glow, drawn straight rather than blurred — cheaper and smoother."""
    w, h = size
    layer = Image.new("RGB", size, (0, 0, 0))
    px = layer.load()
    cx, cy = centre
    for y in range(h):
        for x in range(w):
            d = math.hypot(x - cx, y - cy) / radius
            if d >= 1:
                continue
            f = (1 - d) ** 2 * peak
            px[x, y] = (int(colour[0] * f), int(colour[1] * f), int(colour[2] * f))
    return layer

def back(size):
    w, h = size
    base = Image.new("RGB", size, NAVY)
    # Two glows in the mark's own colours, placed where its gradient runs: cyan up-left,
    # magenta down-right. Parallax slides the front plane over these, which is the whole point
    # of a layered icon and what a flat square could never do.
    glow = radial(size, (w * 0.34, h * 0.28), w * 0.52, CYAN, 0.30)
    glow2 = radial(size, (w * 0.68, h * 0.76), w * 0.52, MAGENTA, 0.34)
    from PIL import ImageChops
    return ImageChops.add(base, ImageChops.add(glow, glow2))

def scaled_mark(height):
    ratio = MARK.width / MARK.height
    return MARK.resize((max(1, round(height * ratio)), height), Image.LANCZOS)

def middle(size):
    """A soft, enlarged shadow of the mark. Gives the stack a real mid-plane instead of an
    empty one, so the parallax reads as depth rather than a sticker sliding on a wall."""
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    mark = scaled_mark(round(h * 0.80))
    shadow = Image.new("RGBA", mark.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 150), (0, 0), mark)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=max(2, h * 0.035)))
    layer.paste(shadow, ((w - mark.width) // 2, (h - mark.height) // 2 + round(h * 0.02)), shadow)
    return layer

def front(size):
    w, h = size
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    # Sized by height: the mark is taller than wide and the layer is 5:3, so height is what
    # runs out first. 66% leaves the margin tvOS crops into when the icon is focused.
    mark = scaled_mark(round(h * 0.66))
    layer.paste(mark, ((w - mark.width) // 2, (h - mark.height) // 2), mark)
    return layer

def write(stack: pathlib.Path, size, scale_suffix=""):
    for name, image in (("back", back(size)), ("middle", middle(size)), ("front", front(size))):
        target = stack / f"{name.capitalize()}.imagestacklayer/Content.imageset/{name}{scale_suffix}.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        image.save(target)
    print(f"  {stack.name} {size[0]}x{size[1]}{scale_suffix or ' @1x'}")

ROOT = pathlib.Path("Assets.xcassets/App Icon & Top Shelf Image.brandassets")
print("building:")
write(ROOT / "App Icon.imagestack", (400, 240))
write(ROOT / "App Icon.imagestack", (800, 480), "@2x")
write(ROOT / "App Icon - App Store.imagestack", (1280, 768))
