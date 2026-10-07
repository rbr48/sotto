"""The "sotto" wordmark, drawn from strokes (no font needed).

Lowercase, geometric and rounded, in one stroke weight like the icon: the
two t's share one crossbar, and the last o is a speech bubble (the icon's
bubble, in Sotto's purple).

Units: the x-height is 100 (y = 0 at its top, 100 on the baseline), the
stroke is STROKE wide, and every stroke has round ends.
"""
import math

from PIL import Image, ImageDraw

STROKE = 18
H = STROKE / 2


def _y(y):
    """Maps the s's design (drawn for strokes between y 12 and 88) to H."""
    return H + (y - 12) * (100 - 2 * H) / 76


# Each stroke is a list of segments: ('line', p0, p1),
# ('cubic', p0, c1, c2, p3) or ('arc', centre, radius, from°, to°), with
# angles measured clockwise from 3 o'clock (y points down).
_S = [
    ((62, 27), (56, 16), (47, 12), (37, 12)),
    ((37, 12), (23, 12), (14, 19), (14, 31)),
    ((14, 31), (14, 45), (28, 48), (38, 51)),
    ((38, 51), (51, 54), (63, 58), (63, 70)),
    ((63, 70), (63, 82), (52, 88), (37, 88)),
    ((37, 88), (24, 88), (15, 83), (11, 73)),
]
S = [[('cubic', *[(x - 2, _y(y)) for x, y in curve]) for curve in _S]]


def _o(cx):
    return [[('arc', (cx, 50), 50 - H, 0, 360)]]


def _t_stem(x):
    foot = 100 - H
    return [
        ('line', (x, -30), (x, foot - 22)),
        ('arc', (x + 22, foot - 22), 22, 180, 90),
        ('line', (x + 22, foot), (x + 24, foot)),
    ]


T1, T2 = 212, 262  # the t stems
O1, O2 = 137, 360  # the centres of the o's
LETTERS = S + _o(O1) + [
    _t_stem(T1),
    _t_stem(T2),
    [('line', (T1 - 18, H), (T2 + 26, H))],  # the shared crossbar
]
BUBBLE = _o(O2)
# The bubble's tail, as in the icon: two points on the o and the tip, in
# multiples of its outer radius (50).
TAIL = [(-0.62, 0.62), (-0.08, 0.98), (-0.98, 1.08)]

LEFT, RIGHT = 0, O2 + 50
TOP, BOTTOM = -30 - H, 50 + 50 * 1.08


def _points(segment, step):
    kind = segment[0]
    if kind == 'line':
        (x0, y0), (x1, y1) = segment[1:]
        n = max(1, math.ceil(math.dist((x0, y0), (x1, y1)) / step))
        return [(x0 + (x1 - x0) * i / n, y0 + (y1 - y0) * i / n) for i in range(n + 1)]
    if kind == 'cubic':
        p0, c1, c2, p3 = segment[1:]
        length = math.dist(p0, c1) + math.dist(c1, c2) + math.dist(c2, p3)
        n = max(1, math.ceil(length / step))
        out = []
        for i in range(n + 1):
            t = i / n
            a, b, c, d = (1 - t) ** 3, 3 * (1 - t) ** 2 * t, 3 * (1 - t) * t ** 2, t ** 3
            out.append((a * p0[0] + b * c1[0] + c * c2[0] + d * p3[0], a * p0[1] + b * c1[1] + c * c2[1] + d * p3[1]))
        return out
    (cx, cy), r, a0, a1 = segment[1:]
    n = max(1, math.ceil(abs(a1 - a0) * math.pi / 180 * r / step))
    return [
        (cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
        for i in range(n + 1)
    ]


def render(height, ink, accent, supersample=4):
    """The wordmark as an image `height` pixels tall (tail included)."""
    scale = height * supersample / (BOTTOM - TOP)
    width = math.ceil((RIGHT - LEFT) * scale)
    image = Image.new('RGBA', (width, math.ceil(height * supersample)), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    radius = H * scale
    step = 0.25 / scale * 4

    def at(x, y):
        return ((x - LEFT) * scale, (y - TOP) * scale)

    def stroke(paths, colour):
        for path in paths:
            for segment in path:
                for x, y in _points(segment, step):
                    px, py = at(x, y)
                    draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=colour)

    stroke(LETTERS, ink)
    stroke(BUBBLE, accent)
    draw.polygon([at(O2 + dx * 50, 50 + dy * 50) for dx, dy in TAIL], fill=accent)
    return image.resize((round(image.width / supersample), height), Image.LANCZOS)


def svg(ink, accent):
    """The same drawing as SVG."""
    def f(v):
        return f'{v:.2f}'.rstrip('0').rstrip('.')

    def d(path):
        out = []
        for segment in path:
            kind = segment[0]
            if kind == 'line':
                (x0, y0), (x1, y1) = segment[1:]
                out.append(f'M{f(x0)} {f(y0)}L{f(x1)} {f(y1)}' if not out else f'L{f(x1)} {f(y1)}')
            elif kind == 'cubic':
                p0, c1, c2, p3 = segment[1:]
                if not out:
                    out.append(f'M{f(p0[0])} {f(p0[1])}')
                out.append(f'C{f(c1[0])} {f(c1[1])} {f(c2[0])} {f(c2[1])} {f(p3[0])} {f(p3[1])}')
            else:
                (cx, cy), r, a0, a1 = segment[1:]
                if abs(a1 - a0) >= 360:
                    out.append(f'M{f(cx - r)} {f(cy)}a{f(r)} {f(r)} 0 1 0 {f(2 * r)} 0a{f(r)} {f(r)} 0 1 0 {f(-2 * r)} 0')
                    continue
                x0, y0 = cx + r * math.cos(math.radians(a0)), cy + r * math.sin(math.radians(a0))
                x1, y1 = cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))
                if not out:
                    out.append(f'M{f(x0)} {f(y0)}')
                sweep = 1 if a1 > a0 else 0
                large = 1 if abs(a1 - a0) > 180 else 0
                out.append(f'A{f(r)} {f(r)} 0 {large} {sweep} {f(x1)} {f(y1)}')
        return ''.join(out)

    width, height = RIGHT - LEFT, BOTTOM - TOP
    stroke = f'stroke-width="{STROKE}" stroke-linecap="round" stroke-linejoin="round" fill="none"'
    tail = ' '.join(f'{f(O2 + dx * 50)},{f(50 + dy * 50)}' for dx, dy in TAIL)
    return '\n'.join([
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{f(LEFT)} {f(TOP)} {f(width)} {f(height)}">',
        f'<path d="{"".join(d(p) for p in LETTERS)}" stroke="{ink}" {stroke}/>',
        f'<path d="{"".join(d(p) for p in BUBBLE)}" stroke="{accent}" {stroke}/>',
        f'<polygon points="{tail}" fill="{accent}"/>',
        '</svg>',
    ]) + '\n'
