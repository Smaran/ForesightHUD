# Draws the 256x256 package icon: a pixel-art eye on a playing card, on the mod's purple.
from PIL import Image, ImageDraw

S = 64  # drawn at 64x64, upscaled 4x (nearest) for a crisp pixel look like Balatro's art
im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(im)
PURPLE, DARK, CARD, EDGE = (142, 68, 173, 255), (52, 24, 68, 255), (246, 242, 230, 255), (40, 40, 52, 255)
GOLD, BLUE, RED = (240, 190, 60, 255), (60, 140, 230, 255), (230, 70, 60, 255)

d.rounded_rectangle([0, 0, S - 1, S - 1], radius=10, fill=PURPLE)
d.rounded_rectangle([3, 3, S - 4, S - 4], radius=8, outline=DARK, width=2)
# card, tilted look via a back card
d.rounded_rectangle([20, 9, 50, 53], radius=3, fill=(120, 52, 150, 255), outline=DARK)
d.rounded_rectangle([14, 11, 44, 55], radius=3, fill=CARD, outline=EDGE)
# eye
d.ellipse([17, 24, 41, 42], fill=(255, 255, 255, 255), outline=EDGE, width=2)
d.ellipse([24, 27, 34, 39], fill=BLUE, outline=EDGE)
d.ellipse([27, 30, 31, 35], fill=EDGE)
d.rectangle([26, 29, 27, 30], fill=(255, 255, 255, 255))
# corner pips
d.text((16, 12), "A", fill=RED)
d.polygon([(40, 47), (42, 50), (40, 53), (38, 50)], fill=RED)
# sparkle
for x, y in ((52, 10), (9, 50)):
    d.line([(x - 2, y), (x + 2, y)], fill=GOLD)
    d.line([(x, y - 2), (x, y + 2)], fill=GOLD)

im.resize((256, 256), Image.NEAREST).save("icon.png")
print("icon.png", Image.open("icon.png").size)
