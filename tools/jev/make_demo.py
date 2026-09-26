#!/usr/bin/env python3
"""Render docs/demo.mp4 and docs/demo.gif.

A fictional thread: he opens with a pickup line, she is not impressed.
He runs Jev from the menu bar twice. The panel copies the real Mac
ReplyPanel: Risk, spaced mood chips, intent, needs, reply cards with
Fill and Copy. Fill writes the compose box. He presses send himself.

Drawn at 2x and scaled down so text stays sharp.
"""
from __future__ import annotations

import math
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parents[2]
OUT_MP4 = ROOT / "docs" / "demo.mp4"
OUT_GIF = ROOT / "docs" / "demo.gif"
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"

W, H = 1280, 800
S = 2
FPS = 30
DURATION = 13.6

SF = "/System/Library/Fonts/SFNS.ttf"
_fonts: dict[tuple[int, str], ImageFont.FreeTypeFont] = {}


def font(size: float, weight: str = "Regular") -> ImageFont.FreeTypeFont:
    key = (int(size * S), weight)
    if key not in _fonts:
        f = ImageFont.truetype(SF, key[0])
        f.set_variation_by_name(weight)
        _fonts[key] = f
    return _fonts[key]


def p(v: float) -> int:
    return int(round(v * S))


def box(x0, y0, x1, y1):
    return (p(x0), p(y0), p(x1), p(y1))


def clamp(v: float, lo: float = 0.0, hi: float = 1.0) -> float:
    return max(lo, min(hi, v))


def ease(v: float) -> float:
    v = clamp(v)
    return v * v * (3 - 2 * v)


def ease_out(v: float) -> float:
    v = clamp(v)
    return 1 - (1 - v) ** 3


def text_w(d: ImageDraw.ImageDraw, s: str, f) -> float:
    return d.textlength(s, font=f) / S


def wrap(d: ImageDraw.ImageDraw, s: str, f, max_w: float) -> list[str]:
    out, cur = [], ""
    for word in s.split():
        trial = (cur + " " + word).strip()
        if text_w(d, trial, f) <= max_w or not cur:
            cur = trial
        else:
            out.append(cur)
            cur = word
    return out + ([cur] if cur else [])


# ---------------------------------------------------------------- palette

DESK_TOP = (18, 28, 40)
DESK_BOT = (10, 36, 38)
WIN_BG = (30, 30, 32)
WIN_EDGE = (62, 62, 66)
TITLE_INK = (235, 235, 240)
MUTED_INK = (152, 152, 160)
BLUE = (10, 132, 255)
GRAY_BUBBLE = (58, 58, 60)
WHITE = (255, 255, 255)

PANEL_BG = (38, 39, 43)
PANEL_EDGE = (78, 80, 86)
CARD_BG = (47, 49, 54)
CARD_EDGE = (74, 76, 82)
BTN_BG = (66, 68, 74)
BTN_PRESSED = (96, 100, 108)
INK = (237, 240, 245)
MUTED = (173, 184, 196)
CYAN = (46, 191, 179)
OK_GREEN = (64, 184, 107)


def risk_color(n: int):
    if n >= 6:
        return (237, 87, 79)
    if n >= 3:
        return (237, 158, 46)
    return (64, 191, 107)


# ---------------------------------------------------------------- layout

MSG = (40, 64, 800, 752)          # Messages window
PANEL_X, PANEL_Y, PANEL_W = 836, 64, 360
MENU_H = 28
JEV_ITEM = (1034, 0, 1086, MENU_H)
HEADER_H = 84
COMPOSER_H = 60
TRANSCRIPT = (MSG[0] + 1, MSG[1] + HEADER_H, MSG[2] - 1, MSG[3] - COMPOSER_H)

HER = "Maya"


# ---------------------------------------------------------------- script

@dataclass
class Item:
    side: str          # "me" | "her" | "typing" | "stamp"
    text: str
    t_in: float
    t_out: float = 1e9


ITEMS = [
    Item("stamp", "Yesterday 4:12 PM", -1),
    Item("her", "did you take my seat in the library", -1),
    Item("me", "i was keeping it warm for you", -1),
    Item("her", "weird. but thanks", -1),
    Item("stamp", "Today 9:41 PM", -1),
    Item("me", "be honest. are you a parking ticket", 0.3),
    Item("typing", "", 0.85, 1.45),
    Item("her", "why", 1.45),
    Item("me", "because you've got FINE written all over you", 1.95),
    Item("typing", "", 2.45, 3.1),
    Item("her", "sir. it is tuesday.", 3.1),
    Item("me", "fair. i'll retire the parking ticket bit", 7.15),
    Item("typing", "", 7.6, 8.2),
    Item("her", "good. what's the replacement bit", 8.2),
    Item("her", "it better involve food", 8.75),
]

PANEL1 = {
    "risk": 3,
    "moods": [("Frustrated", 52), ("Playful", 31), ("Unsure", 17)],
    "intent": "topic closed",
    "needs": "Needs (nothing) · say less · Hold off on specifics",
    "tension": False,
    "replies": [
        (61, "fair. i'll retire the parking ticket bit"),
        (27, "ok that one was bad. tuesday deserves better"),
        (12, "respectfully, you almost laughed"),
    ],
}

PANEL2 = {
    "risk": 1,
    "moods": [("Playful", 48), ("Warm", 34), ("Flirty", 18)],
    "intent": "wants action",
    "needs": "Needs a concrete action · make a plan · OK to give specifics",
    "tension": True,
    "replies": [
        (58, "tacos saturday. i'm buying, you rate my jokes"),
        (29, "brunch sunday? zero pickup lines, promise"),
        (13, "food and no puns. deal?"),
    ],
}

ANALYZING = {"status": "Analyzing…"}
FILLED = {"status": "Filled in. Review it, then send it yourself."}

# (time, x, y) cursor waypoints. (0, 0) is replaced by the panel's Fill button.
CURSOR = [
    (0.0, 560, 470), (3.4, 560, 470), (3.85, 1058, 14), (3.95, 1058, 14),
    (4.25, 1030, 47), (4.4, 1030, 47),
    (5.9, 1000, 420), (6.5, 0, 0), (6.7, 0, 0),
    (7.0, 600, 718), (7.2, 600, 718),
    (8.8, 600, 718), (9.3, 1058, 14), (9.4, 1058, 14),
    (9.7, 1030, 47), (9.85, 1030, 47),
    (11.5, 1000, 460), (12.1, 0, 0), (13.6, 0, 0),
]
CLICKS = [3.9, 4.35, 6.6, 7.1, 9.35, 9.8, 12.2]
MENU_OPEN = [(3.9, 4.4), (9.35, 9.85)]
FILL_PRESS = [(6.52, 6.65), (12.12, 12.25)]


def panel_state(t: float):
    """(state, previous state, crossfade 0..1)."""
    steps = [
        (4.4, ANALYZING), (4.95, PANEL1), (6.65, FILLED),
        (9.85, ANALYZING), (10.4, PANEL2), (12.25, FILLED),
    ]
    cur, prev, since = None, None, 0.0
    for at, st in steps:
        if t >= at:
            prev, cur, since = cur, st, at
    if cur is None:
        return None, None, 1.0
    return cur, prev, ease((t - since) / 0.18)


def composer_text(t: float) -> str:
    if 6.65 <= t < 7.12:
        return PANEL1["replies"][0][1]
    if t >= 12.25:
        return PANEL2["replies"][0][1]
    return ""


def caption(t: float) -> str:
    if t < 3.6:
        return "He opens with a pickup line."
    if t < 7.1:
        return "Analyze #1 · Jev reads her mood and ranks safer replies."
    if t < 9.3:
        return "He sends the safer one himself. She softens."
    return "Analyze #2 · new mood, a real plan. Send stays his."


# ---------------------------------------------------------------- drawing helpers

def rrect(d, b, r, fill, outline=None, width=1):
    d.rounded_rectangle(box(*b), radius=p(r), fill=fill, outline=outline, width=p(width) if outline else 0)


def shadow_layer(size, rect, radius, blur, alpha, dy):
    sh = Image.new("RGBA", size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    x0, y0, x1, y1 = rect
    sd.rounded_rectangle(box(x0, y0 + dy, x1, y1 + dy), radius=p(radius), fill=(0, 0, 0, alpha))
    return sh.filter(ImageFilter.GaussianBlur(p(blur)))


def traffic_lights(d, x, y, active=True, r=6):
    colors = [(255, 95, 87), (254, 188, 46), (40, 200, 64)] if active else [(255, 95, 87), (86, 86, 90), (86, 86, 90)]
    for i, c in enumerate(colors):
        cx = x + i * (r * 2 + 8)
        d.ellipse(box(cx, y, cx + r * 2, y + r * 2), fill=c)


# ---------------------------------------------------------------- static base

def build_base() -> Image.Image:
    img = Image.new("RGBA", (p(W), p(H)))
    grad = Image.linear_gradient("L").resize((p(W), p(H)))
    img.paste(Image.composite(Image.new("RGBA", img.size, DESK_BOT + (255,)),
                              Image.new("RGBA", img.size, DESK_TOP + (255,)), grad))
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(box(700, 360, 1400, 1000), fill=(46, 191, 179, 46))
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(p(120))))

    d = ImageDraw.Draw(img)
    # menu bar
    d.rectangle(box(0, 0, W, MENU_H), fill=(24, 26, 30, 235))
    x = 16
    d.text((p(x), p(6)), "\uF8FF", font=font(14, "Semibold"), fill=INK)
    x += 30
    for i, item in enumerate(["Messages", "File", "Edit", "View", "Conversation", "Window", "Help"]):
        f = font(13, "Bold" if i == 0 else "Regular")
        d.text((p(x), p(6)), item, font=f, fill=INK)
        x += text_w(d, item, f) + 20
    d.text((p(W - 128), p(6)), "Tue 9:41 PM", font=font(13), fill=INK)
    d.text((p(W - 178), p(6)), "100%", font=font(12), fill=INK)

    # Messages window
    img.alpha_composite(shadow_layer(img.size, MSG, 12, 22, 150, 14))
    d = ImageDraw.Draw(img)
    rrect(d, MSG, 12, WIN_BG, outline=WIN_EDGE)
    traffic_lights(d, MSG[0] + 18, MSG[1] + 18)
    cx = (MSG[0] + MSG[2]) / 2
    d.ellipse(box(cx - 18, MSG[1] + 12, cx + 18, MSG[1] + 48), fill=(138, 146, 160))
    f = font(15, "Semibold")
    d.text((p(cx - text_w(d, "M", f) / 2), p(MSG[1] + 20)), "M", font=f, fill=WHITE)
    f = font(12, "Medium")
    d.text((p(cx - text_w(d, HER + " ›", f) / 2), p(MSG[1] + 56)), HER + " ›", font=f, fill=TITLE_INK)
    d.line(box(MSG[0] + 1, MSG[1] + HEADER_H - 1, MSG[2] - 1, MSG[1] + HEADER_H - 1), fill=(48, 48, 52), width=p(1))
    return img


# ---------------------------------------------------------------- transcript bubbles

BUBBLE_FONT = 15
BUBBLE_MAX = 420
LINE_H = 20


def render_bubble(side: str, text: str) -> Image.Image:
    scratch = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    if side == "stamp":
        f = font(11, "Medium")
        w = text_w(scratch, text, f)
        im = Image.new("RGBA", (p(w + 4), p(18)), (0, 0, 0, 0))
        ImageDraw.Draw(im).text((p(2), p(2)), text, font=f, fill=MUTED_INK)
        return im
    if side == "typing":
        bw, bh = 62, 36
        im = Image.new("RGBA", (p(bw + 8), p(bh + 4)), (0, 0, 0, 0))
        ImageDraw.Draw(im).rounded_rectangle(box(0, 0, bw, bh), radius=p(18), fill=GRAY_BUBBLE)
        return im
    f = font(BUBBLE_FONT)
    lines = wrap(scratch, text, f, BUBBLE_MAX - 28)
    bw = max(text_w(scratch, ln, f) for ln in lines) + 28
    bh = len(lines) * LINE_H + 16
    size = (p(bw + 8), p(bh + 2))
    fill = BLUE if side == "me" else GRAY_BUBBLE
    ox = 0 if side == "me" else 8
    # The tail lives on its own layer so carving it never bites the bubble.
    tail = Image.new("RGBA", size, (0, 0, 0, 0))
    td = ImageDraw.Draw(tail)
    if side == "me":
        td.ellipse(box(bw - 16, bh - 20, bw + 6, bh), fill=fill)
        td.ellipse(box(bw + 2, bh - 26, bw + 22, bh - 3), fill=(0, 0, 0, 0))
    else:
        td.ellipse(box(ox - 6, bh - 20, ox + 16, bh), fill=fill)
        td.ellipse(box(ox - 22, bh - 26, ox - 2, bh - 3), fill=(0, 0, 0, 0))
    im = tail
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(box(ox, 0, ox + bw, bh), radius=p(18), fill=fill)
    y = 8
    for ln in lines:
        d.text((p(ox + 14), p(y)), ln, font=f, fill=WHITE)
        y += LINE_H
    return im


def draw_transcript(frame: Image.Image, t: float, bubbles: list[Image.Image]):
    x0, y0, x1, y1 = TRANSCRIPT
    view = Image.new("RGBA", (p(x1 - x0), p(y1 - y0)), WIN_BG + (255,))
    gap = 6
    bottom = (y1 - y0) - 14
    placed = []
    for item, im in zip(reversed(ITEMS), reversed(bubbles)):
        if item.t_in < 0:
            grow = 1.0
        else:
            grow = ease((t - item.t_in) / 0.32) - ease((t - item.t_out) / 0.2)
        if grow <= 0.001:
            continue
        h = im.height / S
        bottom -= (h + gap) * grow
        placed.append((item, im, bottom, grow))
    vd = ImageDraw.Draw(view)
    for item, im, top, grow in placed:
        if top + im.height / S < -4:
            continue
        rise = (1 - grow) * 10
        if item.side == "me":
            x = (x1 - x0) - 16 - im.width / S + 8
        elif item.side == "stamp":
            x = ((x1 - x0) - im.width / S) / 2
        elif item.side == "typing":
            x = 22
        else:
            x = 14
        layer = im
        if grow < 1:
            layer = im.copy()
            a = layer.getchannel("A").point(lambda v, g=grow: int(v * g))
            layer.putalpha(a)
        view.alpha_composite(layer, (p(x), p(top + rise)))
        if item.side == "typing":
            for i in range(3):
                bounce = math.sin((t * 7.5) - i * 0.9) * 2.2
                cx = x + 18 + i * 13
                cy = top + rise + 18 - max(bounce, 0)
                shade = 150 + int(60 * max(0.0, math.sin((t * 7.5) - i * 0.9)))
                vd.ellipse(box(cx - 4, cy - 4, cx + 4, cy + 4), fill=(shade, shade, shade, int(255 * grow)))
    frame.alpha_composite(view, (p(x0), p(y0)))


def draw_composer(frame: Image.Image, t: float):
    d = ImageDraw.Draw(frame)
    x0, y0, x1 = MSG[0] + 18, MSG[3] - COMPOSER_H + 12, MSG[2] - 18
    d.ellipse(box(x0, y0 + 3, x0 + 28, y0 + 31), outline=(92, 92, 98), width=p(1.5))
    d.text((p(x0 + 8), p(y0 + 6)), "+", font=font(17, "Medium"), fill=(150, 150, 158))
    rrect(d, (x0 + 40, y0, x1, y0 + 34), 17, (30, 30, 32), outline=(74, 74, 80))
    txt = composer_text(t)
    if txt:
        d.text((p(x0 + 56), p(y0 + 8)), txt, font=font(14), fill=INK)
        if int(t * 2) % 2 == 0:
            cw = text_w(d, txt, font(14))
            d.line(box(x0 + 58 + cw, y0 + 9, x0 + 58 + cw, y0 + 26), fill=BLUE, width=p(1.5))
    else:
        d.text((p(x0 + 56), p(y0 + 8)), "iMessage", font=font(14), fill=(118, 118, 126))


# ---------------------------------------------------------------- menu bar item + menu

MENU_ITEMS = ["Analyze now", "Why isn't it reading?", "✓ Auto-analyze", "-",
              "Set Judge API key…", "Set Reply API key (optional)…", "Set relationship…", "-", "Quit Jev"]
MENU_BOX = (960, 32, 1220, 0)


def draw_jev_item(frame: Image.Image, highlighted: bool):
    x0, y0, x1, y1 = JEV_ITEM
    if highlighted:
        glow = Image.new("RGBA", frame.size, (0, 0, 0, 0))
        rrect(ImageDraw.Draw(glow), (x0 - 4, 3, x1 + 2, MENU_H - 3), 5, (255, 255, 255, 56))
        frame.alpha_composite(glow)
    d = ImageDraw.Draw(frame)
    rrect(d, (x0 + 2, 8, x0 + 18, 19), 4, None, outline=INK, width=1.4)
    d.polygon([(p(x0 + 6), p(19)), (p(x0 + 5), p(23)), (p(x0 + 10), p(19))], fill=INK)
    d.text((p(x0 + 23), p(6)), "Jev", font=font(13, "Medium"), fill=INK)


def draw_menu(frame: Image.Image, t: float, openness: float, hover_first: bool):
    if openness <= 0:
        return
    rows = []
    y = 6
    for it in MENU_ITEMS:
        rows.append((it, y))
        y += 9 if it == "-" else 23
    mh = y + 6
    x0, y0, x1 = MENU_BOX[0], MENU_BOX[1], MENU_BOX[2]
    layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    layer.alpha_composite(shadow_layer(frame.size, (x0, y0, x1, y0 + mh), 8, 12, 140, 6))
    d = ImageDraw.Draw(layer)
    rrect(d, (x0, y0, x1, y0 + mh), 8, (44, 45, 50, 250), outline=(80, 82, 88))
    for it, ry in rows:
        if it == "-":
            d.line(box(x0 + 10, y0 + ry + 4, x1 - 10, y0 + ry + 4), fill=(80, 82, 88), width=p(1))
            continue
        if it == "Analyze now" and hover_first:
            rrect(d, (x0 + 5, y0 + ry, x1 - 5, y0 + ry + 22), 5, BLUE)
        d.text((p(x0 + 16), p(y0 + ry + 3)), it, font=font(13), fill=INK)
    a = layer.getchannel("A").point(lambda v: int(v * openness))
    layer.putalpha(a)
    frame.alpha_composite(layer)


# ---------------------------------------------------------------- Jev panel

def render_panel(state: dict, title: str, pressed: bool = False):
    """Return (RGBA image at 2x, fill-button hotspot in panel coords or None)."""
    pad, gap, title_h = 14, 8, 28
    inner = PANEL_W - pad * 2
    scratch = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    rows: list[tuple[str, object, float]] = []

    def text_row(s, size=13, weight="Regular", color=INK):
        f = font(size, weight)
        lines = wrap(scratch, s, f, inner)
        rows.append(("text", (lines, f, color, size + 4), len(lines) * (size + 4)))

    if "status" in state:
        text_row(state["status"], 13, "Regular", MUTED)
    else:
        text_row(f"Risk {state['risk']} / 9", 16, "Bold", risk_color(state["risk"]))
        fb = font(13, "Bold")
        chip_lines, x = 1, 0.0
        for chip in ["Mood:"] + [f"{n} {v}%" for n, v in state["moods"]]:
            cw = text_w(scratch, chip, fb)
            if x and x + cw > inner:
                chip_lines, x = chip_lines + 1, 0.0
            x += cw + 16
        rows.append(("moods", state["moods"], 18 * chip_lines))
        text_row(f"Their real intent: {state['intent']}", 13, "Bold")
        text_row(state["needs"], 12, "Regular", MUTED)
        if state["tension"]:
            text_row("✓ Tension resolved", 12, "Regular", OK_GREEN)
        text_row("Suggested replies", 12, "Regular", MUTED)
        for pct, body in state["replies"]:
            lines = wrap(scratch, body, font(13), inner - 20)
            rows.append(("card", (pct, lines), 8 + 17 + 4 + len(lines) * 17 + 6 + 22 + 8))

    body_h = pad * 2 + sum(r[2] for r in rows) + gap * max(len(rows) - 1, 0)
    ph = title_h + body_h
    im = Image.new("RGBA", (p(PANEL_W), p(ph)), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle(box(0, 0, PANEL_W - 0.5, ph - 0.5), radius=p(10), fill=PANEL_BG,
                        outline=PANEL_EDGE, width=p(1))
    traffic_lights(d, 10, 8, active=False, r=5.5)
    f = font(12, "Medium")
    label = f"Jev · {title}"
    d.text((p(PANEL_W / 2 - text_w(d, label, f) / 2), p(7)), label, font=f, fill=(200, 202, 208))
    d.line(box(1, title_h - 1, PANEL_W - 1, title_h - 1), fill=(56, 58, 63), width=p(1))

    y = title_h + pad
    hotspot = None
    first_card = True
    for kind, data, h in rows:
        if kind == "text":
            lines, f, color, lh = data
            for ln in lines:
                d.text((p(pad), p(y)), ln, font=f, fill=color)
                y += lh
            y += gap
            continue
        if kind == "moods":
            fb = font(13, "Bold")
            x, cy = pad, y
            for chip in ["Mood:"] + [f"{n} {v}%" for n, v in data]:
                cw = text_w(d, chip, fb)
                if x > pad and x + cw > PANEL_W - pad:
                    x, cy = pad, cy + 18
                d.text((p(x), p(cy)), chip, font=fb, fill=INK)
                x += cw + 16
            y += h + gap
            continue
        pct, lines = data
        d.rounded_rectangle(box(pad, y, PANEL_W - pad, y + h), radius=p(10), fill=CARD_BG,
                            outline=CARD_EDGE, width=p(1))
        d.text((p(pad + 10), p(y + 8)), f"{pct}%", font=font(13, "Bold"), fill=CYAN)
        ty = y + 8 + 17 + 4
        for ln in lines:
            d.text((p(pad + 10), p(ty)), ln, font=font(13), fill=INK)
            ty += 17
        by = ty + 6
        for i, name in enumerate(["Fill", "Copy"]):
            bx = pad + 10 + i * 58
            fill = BTN_PRESSED if (pressed and first_card and name == "Fill") else BTN_BG
            d.rounded_rectangle(box(bx, by, bx + 50, by + 22), radius=p(5), fill=fill)
            fnt = font(12, "Medium")
            d.text((p(bx + 25 - text_w(d, name, fnt) / 2), p(by + 3.5)), name, font=fnt, fill=INK)
            if first_card and name == "Fill":
                hotspot = (bx + 22, by + 12)
        first_card = False
        y += h + gap
    return im, hotspot


# ---------------------------------------------------------------- cursor

def draw_cursor(frame: Image.Image, x: float, y: float, press: float):
    pts = [(0, 0), (0, 17.5), (4.2, 13.6), (7.2, 20.4), (10.2, 19.1), (7.3, 12.4), (12.8, 12.4)]
    scale = 1.25 * (1 - 0.12 * press)
    poly = [(p(x + px * scale), p(y + py * scale)) for px, py in pts]
    layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).polygon([(a + p(1), b + p(2)) for a, b in poly], fill=(0, 0, 0, 110))
    frame.alpha_composite(layer.filter(ImageFilter.GaussianBlur(p(1.6))))
    d = ImageDraw.Draw(frame)
    d.polygon(poly, fill=WHITE, outline=(10, 10, 10), width=p(1.4))


def click_ring(frame: Image.Image, x: float, y: float, age: float):
    if not 0 <= age <= 0.4:
        return
    r = 6 + 22 * ease_out(age / 0.4)
    alpha = int(170 * (1 - age / 0.4))
    layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(box(x - r, y - r, x + r, y + r), outline=(255, 255, 255, alpha), width=p(2))
    frame.alpha_composite(layer)


def cursor_at(t: float, path):
    for (t0, x0, y0), (t1, x1, y1) in zip(path, path[1:]):
        if t0 <= t <= t1:
            k = ease((t - t0) / max(t1 - t0, 1e-6))
            return x0 + (x1 - x0) * k, y0 + (y1 - y0) * k
    return path[-1][1], path[-1][2]


# ---------------------------------------------------------------- caption

def draw_caption(frame: Image.Image, text: str):
    layer = Image.new("RGBA", frame.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    f = font(14, "Medium")
    w = text_w(d, text, f)
    x0 = MSG[0]
    y0 = MSG[3] + 14
    rrect(d, (x0, y0, x0 + w + 28, y0 + 28), 14, (0, 0, 0, 140))
    d.text((p(x0 + 14), p(y0 + 5)), text, font=f, fill=INK)
    frame.alpha_composite(layer)


# ---------------------------------------------------------------- main

def main() -> None:
    base = build_base()
    bubbles = [render_bubble(it.side, it.text) for it in ITEMS]
    panels = {
        "a": render_panel(ANALYZING, HER),
        "p1": render_panel(PANEL1, HER),
        "p1x": render_panel(PANEL1, HER, pressed=True),
        "f": render_panel(FILLED, HER),
        "p2": render_panel(PANEL2, HER),
        "p2x": render_panel(PANEL2, HER, pressed=True),
    }
    fill1 = panels["p1"][1]
    fill2 = panels["p2"][1]
    path = []
    for i, (tt, x, y) in enumerate(CURSOR):
        if (x, y) == (0, 0):
            spot = fill1 if tt < 9 else fill2
            x, y = PANEL_X + spot[0], PANEL_Y + spot[1]
        path.append((tt, x, y))

    def panel_image(state, t):
        if state is ANALYZING:
            return panels["a"][0]
        if state is FILLED:
            return panels["f"][0]
        pressed = any(a <= t < b for a, b in FILL_PRESS)
        if state is PANEL1:
            return panels["p1x" if pressed else "p1"][0]
        return panels["p2x" if pressed else "p2"][0]

    appear_at = 4.4

    def render(t: float) -> Image.Image:
            frame = base.copy()
            draw_transcript(frame, t, bubbles)
            draw_composer(frame, t)

            state, prev, mix = panel_state(t)
            if state is not None:
                show = ease((t - appear_at) / 0.28)
                cur = panel_image(state, t)
                layers = [(cur, mix)]
                if prev is not None and mix < 1:
                    layers.insert(0, (panel_image(prev, t), 1 - mix))
                tallest = max(im.height for im, _ in layers)
                frame.alpha_composite(shadow_layer(frame.size, (PANEL_X, PANEL_Y, PANEL_X + PANEL_W,
                                                   PANEL_Y + tallest / S), 10, 16, int(150 * show), 10))
                for im, a in layers:
                    k = a * show
                    if k <= 0.01:
                        continue
                    layer = im.copy()
                    layer.putalpha(layer.getchannel("A").point(lambda v, k=k: int(v * k)))
                    frame.alpha_composite(layer, (p(PANEL_X + (1 - show) * 24), p(PANEL_Y)))

            menu_open = 0.0
            for a, b in MENU_OPEN:
                if a <= t < b:
                    menu_open = ease((t - a) / 0.08)
            draw_jev_item(frame, menu_open > 0)
            hover = any(a + 0.3 <= t < b for a, b in MENU_OPEN)
            draw_menu(frame, t, menu_open, hover)

            cx, cy = cursor_at(t, path)
            press = max((1 - abs(t - c) / 0.09 for c in CLICKS if abs(t - c) < 0.09), default=0.0)
            for c in CLICKS:
                click_ring(frame, cx, cy, t - c)
            draw_cursor(frame, cx, cy, press)
            draw_caption(frame, caption(t))
            return frame.convert("RGB").resize((W, H), Image.LANCZOS)

    if len(sys.argv) > 2 and sys.argv[1] == "--preview":
        for arg in sys.argv[2:]:
            out = Path(f"/tmp/jev-demo-{arg}.png")
            render(float(arg)).save(out)
            print("wrote", out)
        return

    n = int(DURATION * FPS)
    tmp = Path(tempfile.mkdtemp(prefix="jev-demo-"))
    try:
        for i in range(n):
            render(i / FPS).save(tmp / f"f{i:04d}.png")
            if i % 60 == 0:
                print(f"frame {i}/{n}")

        pattern = str(tmp / "f%04d.png")
        subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", pattern,
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "18", "-preset", "slow",
                        "-movflags", "+faststart", str(OUT_MP4)], check=True)
        subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-framerate", str(FPS), "-i", pattern,
                        "-vf", "fps=15,scale=960:-1:flags=lanczos,split[a][b];"
                               "[a]palettegen=max_colors=128:stats_mode=diff[pal];"
                               "[b][pal]paletteuse=dither=sierra2_4a:diff_mode=rectangle",
                        str(OUT_GIF)], check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print(f"wrote {OUT_MP4} and {OUT_GIF} ({DURATION}s)")


if __name__ == "__main__":
    main()
