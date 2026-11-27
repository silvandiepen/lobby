#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Draws Lobby's icons for every app from the one picture in Brand/portal.svg: a door left open
onto a lit room.

    python3 Scripts/make-icons.py      (needs rsvg-convert and Pillow)

The picture's groups are the layers: background-layer, door-frame, light, open-door, and the glow
on top. The Apple TV gets them apart so they can move under the remote.
"""
import copy, json, os, subprocess
import xml.etree.ElementTree as ET

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NS = 'http://www.w3.org/2000/svg'
ART = 1248  # the picture is 1248 by 1248
ET.register_namespace('', NS)
SOURCE = ET.parse(HERE + '/Brand/portal.svg').getroot()

def find(id):
    return next(e for e in SOURCE.iter() if e.get('id') == id)

def text(e):
    return ET.tostring(e, encoding='unicode')

DEFS = text(SOURCE.find(f'{{{NS}}}defs'))
# Turns a picture grey, for the tinted icon: the system colours it in by how light it is.
GREY = '<filter id="grey"><feColorMatrix type="saturate" values="0"/></filter>'

def parts(*ids, endless=False):
    """The named groups as SVG. Endless stretches the sky and the floor past the square's edges,
    for pictures wider or taller than the square, so nothing ends in a straight cut."""
    out = []
    for id in ids:
        e = copy.deepcopy(find(id))
        if endless:
            for child in e.iter():
                if child.tag == f'{{{NS}}}rect':  # the sky
                    child.attrib.update(x='-20000', y='-20000', width='40000', height='40000')
                elif child.get('id') == 'floor-light':
                    # From the doorway's sill the light runs out along the same two edges forever.
                    child.set('d', 'M530 962H824L9304 5922L-3163 2863L537 1163Z')
                elif child.get('id') == 'floor-shadow':
                    child.set('d', 'M313 968L537 1163L-3163 2863L-5947 3208Z')
        out.append(text(e))
    return ''.join(out)

WHOLE = ('background-layer', 'door-frame', 'light', 'open-door', 'glow')
NO_SKY = WHOLE[1:]

def place(body, size, cx, cy):
    """The picture drawn `size` wide with its centre at (cx, cy)."""
    return f'<g transform="translate({cx - size / 2} {cy - size / 2}) scale({size / ART})">{body}</g>'

def draw(path, w, h, body, size=None, extra=''):
    svg = f'<svg xmlns="{NS}" viewBox="0 0 {w} {h}" width="{w}" height="{h}">{DEFS}<defs>{extra}</defs>{body}</svg>'
    os.makedirs(os.path.dirname(path), exist_ok=True)
    out_w, out_h = size if size else (w, h)
    subprocess.run(['rsvg-convert', '-w', str(out_w), '-h', str(out_h), '-o', path], input=svg.encode(), check=True)

def contents(path, data):
    with open(path + '/Contents.json', 'w') as f:
        json.dump(data, f, indent=2)
        f.write('\n')

INFO = {'author': 'xcode', 'version': 1}

# iPhone and iPad: the picture as it is, and a dark and a tinted one. The system rounds it.
ios = HERE + '/iOS/Assets.xcassets/AppIcon.appiconset'
draw(ios + '/icon.png', 1024, 1024, place(parts(*WHOLE), 1024, 512, 512))
# Dark: the door and its light without the square sky; the system puts its own dark behind it.
draw(ios + '/icon-dark.png', 1024, 1024, place(parts(*NO_SKY), 1024, 512, 512))
# Tinted: the same in grey on black.
draw(ios + '/icon-tinted.png', 1024, 1024,
     '<rect width="1024" height="1024" fill="#000"/>' + f'<g filter="url(#grey)">{place(parts(*NO_SKY), 1024, 512, 512)}</g>',
     extra=GREY)
images = [{'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'}]
for name, value in (('icon-dark.png', 'dark'), ('icon-tinted.png', 'tinted')):
    images.append({'appearances': [{'appearance': 'luminosity', 'value': value}], 'filename': name, 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'})

# The Mac: drawn with its own rounded shape and the margin macOS expects.
shape = '<clipPath id="c"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>'
mac = f'<g clip-path="url(#c)">{place(parts(*WHOLE), 824, 512, 512)}</g>'
for pt in (16, 32, 128, 256, 512):
    for k in (1, 2):
        f = f'mac-{pt}@{k}x.png'
        draw(f'{ios}/{f}', 1024, 1024, mac, (pt * k, pt * k), extra=shape)
        images.append({'filename': f, 'idiom': 'mac', 'scale': f'{k}x', 'size': f'{pt}x{pt}'})
contents(ios, {'images': images, 'info': INFO})

# Apple TV: three layers that move apart under the remote. The sky at the back, the lit doorway
# in the middle, the open door in front; the picture's sky and floor carry on to the wide edges.
tv = HERE + '/tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets'
for stack, w, h, scales in (('App Icon.imagestack', 400, 240, (1, 2)), ('App Icon - App Store.imagestack', 1280, 768, (1,))):
    size = h * .92
    for layer, ids in (('Back', ('background-layer',)), ('Middle', ('door-frame', 'light', 'glow')), ('Front', ('open-door',))):
        for k in scales:
            draw(f'{tv}/{stack}/{layer}.imagestacklayer/Content.imageset/{layer.lower()}@{k}x.png', w, h,
                 place(parts(*ids, endless=True), size, w / 2, h / 2), (w * k, h * k))
for name, w in (('Top Shelf Image', 1920), ('Top Shelf Image Wide', 2320)):
    for k in (1, 2):
        draw(f'{tv}/{name}.imageset/shelf@{k}x.png', w, 720, place(parts(*WHOLE, endless=True), 720 * .8, w / 2, 360), (w * k, 720 * k))

# The kids icon: the owner's painting in Brand/portal-kids.png, the same door with sparkles in a
# yellow doorway. The app switches to it while a kid is the viewer (KidsIcon.swift). It is a
# picture, not layers, so the door and its light are lifted off the dark sky by how far each pixel
# is from the sky's colour: over that sky they add up to the painting again.
from PIL import Image, ImageChops, ImageDraw

KIDS = Image.open(HERE + '/Brand/portal-kids.png').convert('RGB')
SKY = (28, 3, 64)  # the painting's edges, all round

def kids(size):
    return KIDS.resize((size, size), Image.LANCZOS)

def lifted(size):
    """The door and its light without the sky, as RGBA: the sky is see-through, the glow partly."""
    art = kids(size)
    px = art.load()
    out = Image.new('RGBA', (size, size))
    po = out.load()
    for y in range(size):
        for x in range(size):
            r, g, b = px[x, y]
            far = max(abs(r - SKY[0]), abs(g - SKY[1]), abs(b - SKY[2]))
            a = min(1.0, far / 48)
            if a <= 0:
                po[x, y] = (*SKY, 0)
                continue
            # The colour that, at this opacity over the sky, gives the painting's.
            c = [min(255, max(0, round(s + (v - s) / a))) for v, s in zip((r, g, b), SKY)]
            po[x, y] = (*c, round(a * 255))
    return out

def save(image, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path, optimize=True)

# iPhone and iPad: an alternate icon set with the same three looks as the primary. Flat for the
# light one (no alpha), the lifted door over the system's own dark, and grey on black for tinted.
kids_ios = HERE + '/iOS/Assets.xcassets/AppIcon-Kids.appiconset'
save(kids(1024), kids_ios + '/icon.png')
save(lifted(1024), kids_ios + '/icon-dark.png')
door = lifted(1024)
tinted = Image.new('RGB', (1024, 1024), (0, 0, 0))
tinted.paste(door, (0, 0), door)
save(tinted.convert('L').convert('RGB'), kids_ios + '/icon-tinted.png')
contents(kids_ios, {'images': [
    {'filename': 'icon.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
    {'appearances': [{'appearance': 'luminosity', 'value': 'dark'}], 'filename': 'icon-dark.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
    {'appearances': [{'appearance': 'luminosity', 'value': 'tinted'}], 'filename': 'icon-tinted.png', 'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024'},
], 'info': INFO})

# Apple TV: an alternate icon there is one image stack, the home screen's size, beside the brand
# asset (a brand asset is not found as an alternate). The sky at the back, the door and its light
# in front; the painting's square ends softly at its sides, where the floor's light would be cut.
kids_tv = HERE + '/tvOS/Assets.xcassets/AppIcon-Kids-TV.imagestack'
scales = (1, 2)
for k in scales:
    W, H = 400 * k, 240 * k
    save(Image.new('RGB', (W, H), SKY), f'{kids_tv}/Back.imagestacklayer/Content.imageset/back@{k}x.png')
    front = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    door = lifted(H)
    fade = Image.new('L', (H, H), 255)
    d = ImageDraw.Draw(fade)
    edge = H // 12
    for i in range(edge):
        d.line([(i, 0), (i, H)], fill=round(255 * i / edge))
        d.line([(H - 1 - i, 0), (H - 1 - i, H)], fill=round(255 * i / edge))
    door.putalpha(ImageChops.multiply(door.getchannel('A'), fade))
    front.paste(door, ((W - H) // 2, 0))
    save(front, f'{kids_tv}/Front.imagestacklayer/Content.imageset/front@{k}x.png')
for layer in ('Back', 'Front'):
    images = [{'filename': f'{layer.lower()}@{k}x.png', 'idiom': 'tv', 'scale': f'{k}x'} for k in scales]
    contents(f'{kids_tv}/{layer}.imagestacklayer/Content.imageset', {'images': images, 'info': INFO})
    contents(f'{kids_tv}/{layer}.imagestacklayer', {'info': INFO})
contents(kids_tv, {'info': INFO, 'layers': [{'filename': 'Front.imagestacklayer'}, {'filename': 'Back.imagestacklayer'}]})

# The Mac has no alternate icons: in kids mode the Dock shows this, drawn like the Mac's own.
mask = Image.new('L', (1024, 1024), 0)
ImageDraw.Draw(mask).rounded_rectangle((100, 100, 923, 923), radius=185, fill=255)
dock = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
dock.paste(kids(824), (100, 100))
dock.putalpha(mask)
save(dock, HERE + '/macOS/KidsIcon.xcassets/KidsDockIcon.imageset/kids-dock.png')
contents(HERE + '/macOS/KidsIcon.xcassets', {'info': INFO})
contents(HERE + '/macOS/KidsIcon.xcassets/KidsDockIcon.imageset', {'images': [{'filename': 'kids-dock.png', 'idiom': 'mac'}], 'info': INFO})

# The kids screens show the door too: the kids home's mark, the resting and asking screens.
save(kids(600), HERE + '/Shared/Brand.xcassets/KidsDoor.imageset/kids-door.png')
contents(HERE + '/Shared/Brand.xcassets', {'info': INFO})
contents(HERE + '/Shared/Brand.xcassets/KidsDoor.imageset', {'images': [{'filename': 'kids-door.png', 'idiom': 'universal'}], 'info': INFO})
print('done')
