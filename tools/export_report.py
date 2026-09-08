#!/usr/bin/env python3
"""RaidPulse -> a single self-contained HTML report.

Reads the addon's SavedVariables straight off disk rather than asking for an
export string out of the game: the file already holds every saved report with
every player's figures, and a WoW edit box is a poor way to move a few hundred
kilobytes.

    python tools/export_report.py                # auto-detect, write report.html
    python tools/export_report.py --out foo.html
    python tools/export_report.py --sv "path/to/RaidPulse.lua"

SavedVariables are flushed on /reload or logout, so the newest fight is only in
the file after one of those. The page says which file it was built from and how
old that file is.
"""

import argparse
import base64
import math
import datetime as dt
import glob
import html
import os
import re
import struct
import sys
import zlib

# ---------------------------------------------------------------------------
# Reading the SavedVariables
# ---------------------------------------------------------------------------
# WoW writes a very regular subset of Lua: nested tables, ["string"] or [number]
# keys, bare values for array entries, and string/number/boolean/nil leaves.
# A focused parser for that subset keeps this script dependency-free.

_NUMBER = re.compile(r"-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
_WS = re.compile(r"(?:\s|--[^\n]*)+")


class LuaSyntaxError(RuntimeError):
    pass


class _Reader:
    def __init__(self, text):
        self.s = text
        self.i = 0

    def ws(self):
        m = _WS.match(self.s, self.i)
        if m:
            self.i = m.end()

    def expect(self, ch):
        self.ws()
        if self.i >= len(self.s) or self.s[self.i] != ch:
            got = self.s[self.i:self.i + 20] if self.i < len(self.s) else "<eof>"
            raise LuaSyntaxError("expected %r at offset %d, found %r" % (ch, self.i, got))
        self.i += 1

    def string(self):
        self.expect('"')
        out = []
        while True:
            if self.i >= len(self.s):
                raise LuaSyntaxError("unterminated string")
            c = self.s[self.i]
            if c == "\\":
                nxt = self.s[self.i + 1]
                out.append({"n": "\n", "t": "\t", "r": "\r"}.get(nxt, nxt))
                self.i += 2
            elif c == '"':
                self.i += 1
                return "".join(out)
            else:
                out.append(c)
                self.i += 1

    def value(self):
        self.ws()
        c = self.s[self.i]
        if c == "{":
            return self.table()
        if c == '"':
            return self.string()
        if self.s.startswith("true", self.i):
            self.i += 4
            return True
        if self.s.startswith("false", self.i):
            self.i += 5
            return False
        if self.s.startswith("nil", self.i):
            self.i += 3
            return None
        m = _NUMBER.match(self.s, self.i)
        if m:
            self.i = m.end()
            raw = m.group(0)
            return float(raw) if ("." in raw or "e" in raw or "E" in raw) else int(raw)
        raise LuaSyntaxError("unparsable value at offset %d: %r"
                             % (self.i, self.s[self.i:self.i + 20]))

    def table(self):
        self.expect("{")
        out = {}
        nxt_index = 1
        while True:
            self.ws()
            if self.i >= len(self.s):
                raise LuaSyntaxError("unterminated table")
            if self.s[self.i] == "}":
                self.i += 1
                return out
            if self.s[self.i] == "[":
                self.i += 1
                self.ws()
                key = self.string() if self.s[self.i] == '"' else self.value()
                self.expect("]")
                self.expect("=")
                out[key] = self.value()
            else:
                out[nxt_index] = self.value()
                nxt_index += 1
            self.ws()
            if self.i < len(self.s) and self.s[self.i] in ",;":
                self.i += 1


def load_saved_variables(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    m = re.search(r"RaidPulseDB\s*=\s*", text)
    if not m:
        raise LuaSyntaxError("no RaidPulseDB assignment in %s" % path)
    reader = _Reader(text)
    reader.i = m.end()
    return reader.table()


def find_saved_variables():
    """The account folder is named after the account id, so glob for it."""
    here = os.path.dirname(os.path.abspath(__file__))
    wow = os.path.abspath(os.path.join(here, "..", "..", "..", ".."))
    pattern = os.path.join(wow, "WTF", "Account", "*", "SavedVariables", "RaidPulse.lua")
    hits = sorted(glob.glob(pattern), key=os.path.getmtime, reverse=True)
    return hits[0] if hits else None


def report_day(report):
    """The calendar day of an attempt, as dd/mm/yyyy.

    Read from savedAt, which is the string every label in the addon shows,
    rather than recomputed from the epoch: two sources for one date drift the
    moment a timezone or a midnight is involved.
    """
    stamp = str((report or {}).get("savedAt") or "")
    m = re.match(r"^(\d{2})/(\d{2})/(\d{4})", stamp)
    if m:
        return "%s/%s/%s" % m.groups()
    m = re.match(r"^(\d{2})/(\d{2})\b", stamp)
    if m:
        return "%s/%s" % m.groups()
    return None


def parse_day(text):
    """dd/mm/yyyy, dd/mm, or yyyy-mm-dd, all normalised to what report_day
    returns. Anything else is refused rather than silently matching nothing."""
    text = (text or "").strip()
    m = re.match(r"^(\d{4})-(\d{2})-(\d{2})$", text)
    if m:
        return "%s/%s/%s" % (m.group(3), m.group(2), m.group(1))
    m = re.match(r"^(\d{1,2})/(\d{1,2})/(\d{4})$", text)
    if m:
        return "%02d/%02d/%s" % (int(m.group(1)), int(m.group(2)), m.group(3))
    m = re.match(r"^(\d{1,2})/(\d{1,2})$", text)
    if m:
        return "%02d/%02d" % (int(m.group(1)), int(m.group(2)))
    raise SystemExit("--day %s: usa dd/mm/aaaa, dd/mm oppure aaaa-mm-gg" % text)


def filter_by_day(history, day):
    """Both forms compare on the day, so --day 08/09 matches 08/09/2026."""
    if not day:
        return history
    hits = []
    for report in history:
        got = report_day(report)
        if not got:
            continue
        if got == day or got.startswith(day + "/") or day.startswith(got + "/"):
            hits.append(report)
    return hits


def as_list(table):
    """A Lua array comes back as {1: v, 2: v}; give it back in order."""
    if not isinstance(table, dict):
        return []
    keys = [k for k in table if isinstance(k, int)]
    return [table[k] for k in sorted(keys)]


def _png(width, height, rgba):
    """A minimal PNG writer. The icon ships as an uncompressed TGA, which no
    browser reads, and pulling in an imaging library for one 128px logo is not
    worth it."""
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)                       # filter: none
        raw += rgba[y * stride:(y + 1) * stride]

    def chunk(tag, payload):
        body = tag + payload
        return (struct.pack(">I", len(payload)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def icon_data_uri():
    """The addon icon as a data URI, or None if it cannot be read.

    Only uncompressed true-colour TGA is handled, which is what the addon
    ships; anything else falls back to the drawn mark.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "Textures", "icon.tga")
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError:
        return None

    if len(data) < 18 or data[2] != 2 or data[16] != 32:
        return None

    width, height = struct.unpack("<HH", data[12:16])
    start = 18 + data[0]
    pixels = data[start:start + width * height * 4]
    if len(pixels) < width * height * 4:
        return None

    # TGA stores BGRA, and bottom-up unless bit 5 of the descriptor says
    # otherwise.
    rgba = bytearray(len(pixels))
    for i in range(0, len(pixels), 4):
        b, g, r, a = pixels[i:i + 4]
        rgba[i:i + 4] = bytes((r, g, b, a))

    if not (data[17] & 0x20):
        stride = width * 4
        rows = [rgba[y * stride:(y + 1) * stride] for y in range(height)]
        rgba = bytearray(b"".join(reversed(rows)))

    return "data:image/png;base64," + base64.b64encode(
        _png(width, height, rgba)).decode("ascii")


FALLBACK_MARK = (
    '<svg viewBox="0 0 64 64" class="mark" role="img" aria-label="RaidPulse">'
    '<circle cx="32" cy="32" r="30" fill="#1b1030" stroke="#a855f7" stroke-width="2"/>'
    '<path d="M10 32h10l5-12 7 24 6-16 5 8h11" fill="none" stroke="#c084fc"'
    ' stroke-width="3" stroke-linejoin="round" stroke-linecap="round"/></svg>'
)


# ---------------------------------------------------------------------------
# The same definitions the addon uses
# ---------------------------------------------------------------------------

CLASS_COLORS = {
    "WARRIOR": "#C69B6D", "PALADIN": "#F48CBA", "HUNTER": "#AAD372",
    "ROGUE": "#FFF468", "PRIEST": "#FFFFFF", "DEATHKNIGHT": "#C41E3A",
    "SHAMAN": "#0070DD", "MAGE": "#3FC7EB", "WARLOCK": "#8788EE",
    "MONK": "#00FF98", "DRUID": "#FF7C0A", "DEMONHUNTER": "#A330C9",
    "EVOKER": "#33937F",
}

KILL, WIPE = "#55dd55", "#ff5555"

# A key level as the addon stores it: the difficulty string is "+12".
KEY_LEVEL = re.compile(r"^\+(\d+)$")


def num(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def get_dps(p):
    if num(p.get("blizzardDps")) > 0:
        return num(p["blizzardDps"])
    bl = p.get("blizzard") or {}
    inner = bl.get("dps") or {}
    if num(inner.get("amountPerSecond")) > 0:
        return num(inner["amountPerSecond"])
    for k in ("dps", "fightDPS", "damagePerSecond"):
        if num(p.get(k)) > 0:
            return num(p[k])
    return 0.0


def _first(p, *keys):
    for k in keys:
        if num(p.get(k)) > 0:
            return num(p[k])
    return 0.0


METRICS = [
    {"key": "dps",     "label": "DPS",            "kind": "rate",  "better": 1,
     "get": get_dps, "color": "class"},
    {"key": "damage",  "label": "Damage Overall", "kind": "rate",  "better": 1,
     "get": lambda p: _first(p, "blizzardDamageDone", "damageDone"), "color": "class"},
    {"key": "hps",     "label": "HPS",            "kind": "rate",  "better": 1,
     "get": lambda p: _first(p, "blizzardHps", "hps"), "color": "#2ecc71"},
    {"key": "healing", "label": "Heal Overall",   "kind": "rate",  "better": 1,
     "get": lambda p: _first(p, "blizzardHealingDone", "healingDone"), "color": "#2ecc71"},
    {"key": "taken",   "label": "Damage Taken/s", "kind": "rate",  "better": 0,
     "get": lambda p: num(p.get("_dtps")), "color": "#e67e22"},
    {"key": "parse",   "label": "Parse",          "kind": "count", "better": 1,
     "get": lambda p: num(p.get("mcaRating")), "color": "#c74ffb"},
    {"key": "deaths",  "label": "Morti",          "kind": "count", "better": -1,
     "get": lambda p: num(p.get("deaths")), "color": "#c0392b"},
]
METRIC_BY_KEY = {m["key"]: m for m in METRICS}

# The shape each metric is drawn as on a player card. Chosen by the question
# the metric answers, not by its name.
#
#   auto     bars while the columns are few, a line once they are many: with
#            eighteen pulls a row of bars is a picket fence, and the message is
#            the trajectory. A line between two pulls asserts a continuity that
#            does not exist -- nothing happened between pull 3 and pull 4 --
#            so it is never the default, only what many points earn.
#   gauge    a fixed 0..100 axis. A percentile auto-scaled to its own maximum
#            is a lie: a parse of 24 filled the card.
#   scatter  duration against total, where a diagonal is a constant rate. A
#            total is nearly always its rate times the length of the pull, so
#            as bars it repeats the rate chart; against duration it finally
#            answers whether a big number was a good pull or a long one.
#   timeline the pull from 0 to its duration with a tick per death. For deaths
#            the count is not the story, the moment is.
CHART_FORM = {
    "dps": "auto", "hps": "auto", "taken": "auto",
    "damage": "scatter", "healing": "scatter",
    "parse": "gauge",
    "deaths": "timeline",
}

# Past this many columns a line reads better than bars.
LINE_FROM = 7


def normalise(history):
    """Derived fields the metrics read, computed once per load.

    Damage taken is charted per second: the total rewards whoever survived
    longest, which is the opposite of what it is meant to show. The meter
    supplies a per-second figure, and where it only supplied a total the pull's
    own duration turns it into one.
    """
    for report in history:
        duration = num(report.get("duration"))
        for row in (report.get("players") or {}).values():
            if not isinstance(row, dict):
                continue
            dtps = num(row.get("blizzardDtps"))
            if dtps <= 0:
                total = _first(row, "blizzardDamageTaken", "damageTaken")
                dtps = (total / duration) if (total > 0 and duration > 0) else 0
            row["_dtps"] = dtps
    return history

ROLE_CHARTS = {
    "TANK":    ["taken", "dps", "damage", "parse", "deaths"],
    "HEALER":  ["hps", "healing", "parse", "deaths"],
    "DAMAGER": ["dps", "damage", "parse", "deaths"],
}

ROLE_LABEL = {"TANK": "Tank", "HEALER": "Healer", "DAMAGER": "DPS", "NONE": "DPS"}


def fight_key(report):
    """Raids are scoped to their group; M+ runs of one dungeon share a bucket,
    because the group disbands at the end of every key."""
    boss = str(report.get("boss") or "?")
    if report.get("type") == "M+":
        return boss + "||*"
    return boss + "||" + str(report.get("groupID") or "legacy")


def attempt_label(report):
    stamp = str(report.get("savedAt") or "")
    m = re.search(r"(\d\d:\d\d)\s*$", stamp)
    label = m.group(1) if m else stamp
    if report.get("type") == "M+":
        lvl = re.match(r"^\+\d+$", str(report.get("difficulty") or ""))
        if lvl:
            label += " " + lvl.group(0)
    return label


def fmt_rate(v):
    v = num(v)
    if v <= 0:
        return "-"
    if v >= 1_000_000:
        return "%.2fM" % (v / 1_000_000)
    if v >= 1000:
        return "%.0fk" % (v / 1000)
    return str(int(v))


def fmt_count(v):
    return str(int(num(v)))


def formatter(metric):
    return fmt_rate if metric["kind"] == "rate" else fmt_count


def verdict(metric, old, new):
    """'better', 'worse' or None, with the addon's 5% deadband on rates."""
    if metric["better"] == 0:
        return None
    if metric["kind"] == "rate":
        if old <= 0:
            return None
        change = (new - old) / old
        if abs(change) < 0.05:
            return None
        up = change > 0
    else:
        if new == old:
            return None
        up = new > old
    return "better" if up == (metric["better"] > 0) else "worse"


# ---------------------------------------------------------------------------
# Building the page
# ---------------------------------------------------------------------------

def esc(text):
    return html.escape(str(text), quote=True)


def class_color(player):
    return CLASS_COLORS.get(str((player or {}).get("class") or "").upper(), "#dddddd")


def collect_fights(history):
    fights = {}
    for report in history:
        if not report.get("boss") or not report.get("historyID"):
            continue
        key = fight_key(report)
        fights.setdefault(key, []).append(report)

    out = []
    for key, reports in fights.items():
        reports.sort(key=lambda r: num(r.get("savedAtEpoch")))
        out.append({
            "key": key,
            "boss": str(reports[0].get("boss")),
            "type": reports[0].get("type") or "raid",
            "group": reports[0].get("groupID"),
            "reports": reports,
            "latest": num(reports[-1].get("savedAtEpoch")),
        })
    out.sort(key=lambda f: -f["latest"])
    return out


def collect_containers(history):
    """What gets one section of the page.

    A dungeon is its own container: every run of it is pooled already. A raid
    night is not -- the group is the unit of work, and "how did the night go"
    means every boss and every pull in it, not one boss at a time. So raid
    fights are gathered under their group and the bosses become subsections.
    """
    containers = {}
    for fight in collect_fights(history):
        if fight["type"] == "M+":
            key, kind = "mplus::" + fight["key"], "mplus"
        else:
            key, kind = "raid::" + str(fight["group"] or "legacy"), "raid"

        box = containers.get(key)
        if box is None:
            box = {"key": key, "kind": kind, "fights": [], "reports": []}
            containers[key] = box
        box["fights"].append(fight)
        box["reports"].extend(fight["reports"])

    out = []
    for box in containers.values():
        box["reports"].sort(key=lambda r: num(r.get("savedAtEpoch")))
        box["fights"].sort(key=lambda f: num(f["reports"][0].get("savedAtEpoch")))
        box["first"] = num(box["reports"][0].get("savedAtEpoch"))
        box["latest"] = num(box["reports"][-1].get("savedAtEpoch"))
        out.append(box)

    out.sort(key=lambda b: -b["latest"])
    return out


def when(epoch, fmt="%d/%m %H:%M"):
    if not epoch:
        return "?"
    return dt.datetime.fromtimestamp(epoch).strftime(fmt)


def players_of(fight):
    """Every player seen in any attempt, with the most recent row for each."""
    latest = {}
    for report in fight["reports"]:
        for p in (report.get("players") or {}).values():
            if isinstance(p, dict) and p.get("name"):
                latest[p["name"]] = p
    return latest


def appearances(fight, name):
    return sum(1 for r in fight["reports"]
               if isinstance((r.get("players") or {}).get(name), dict))


def ordered_players(fight, players, metric=None):
    """Whoever was there for the most attempts first.

    An M+ dungeon pools runs made with different groups, so the player list is
    the union of all of them: sorting on a single figure would bury the people
    who ran several keys with you under strangers who appear once and are
    "assente" everywhere else. Within the same number of appearances the
    metric decides.
    """
    getter = metric["get"] if metric else get_dps
    last = fight["reports"][-1].get("players") or {}
    return sorted(
        players,
        key=lambda n: (-appearances(fight, n), -getter(last.get(n) or {}), n),
    )


def nice_ticks(top, wanted=3, integer=False):
    """Round gridline values at or below `top`.

    Bars alone give a ratio and nothing else: 86k beside 36k looks the same as
    860k beside 360k. A labelled scale is what turns the picture back into
    quantities.

    `wanted` is biased down by half a line, or a top of 16.7M picks a 10M step
    and draws a single gridline where 5M would have drawn three. `integer`
    keeps a count metric off fractional steps, which would otherwise label a
    chart topping out at one death with "0" and "1".
    """
    if top <= 0:
        return []

    raw = top / (float(wanted) + 0.5)
    magnitude = 10 ** math.floor(math.log10(raw))
    step = 10 * magnitude
    for candidate in (1, 2, 2.5, 5, 10):
        if raw <= candidate * magnitude:
            step = candidate * magnitude
            break

    if integer:
        step = max(1, round(step))

    ticks, value = [], step
    while value <= top * 1.001:
        ticks.append(value)
        value += step
    return ticks


def chart_frame(width, height, top, fmt, integer=False, bands=None):
    """The shared furniture: gridlines, their labels, and the baseline.

    Returns (parts, geometry) so each form draws its own marks on top of one
    set of axes rather than inventing its own.
    """
    pad_l, pad_r, pad_b, pad_t = 42, 8, 34, 20
    plot_h = height - pad_b - pad_t
    plot_w = width - pad_l - pad_r

    def y_of(value):
        return pad_t + plot_h - (value / top * plot_h if top > 0 else 0)

    parts = ['<svg viewBox="0 0 %d %d" class="chart" role="img">' % (width, height)]

    for lo, hi, cls in (bands or []):
        y1, y2 = y_of(hi), y_of(lo)
        parts.append('<rect x="%g" y="%g" width="%g" height="%g" class="%s"/>'
                     % (pad_l, y1, plot_w, max(0, y2 - y1), cls))

    for tick in nice_ticks(top, integer=integer):
        y = y_of(tick)
        parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="grid"/>'
                     % (pad_l, y, width - pad_r, y))
        parts.append('<text x="%g" y="%g" class="t">%s</text>'
                     % (pad_l - 6, y + 3, esc(fmt(tick))))

    parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="axis"/>'
                 % (pad_l, pad_t + plot_h, width - pad_r, pad_t + plot_h))

    return parts, (pad_l, pad_r, pad_t, plot_w, plot_h, y_of)


def average_line(parts, geometry, width, average, fmt):
    """The reference a single column cannot give: above or below normal."""
    pad_l, pad_r, _, _, _, y_of = geometry
    y = y_of(average)
    parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="avg"/>'
                 % (pad_l, y, width - pad_r, y))
    parts.append('<text x="%g" y="%g" class="a">media %s</text>'
                 % (width - pad_r, y - 4, esc(fmt(average))))


def outcome_band(parts, x, y, w, colour):
    parts.append('<rect x="%g" y="%g" width="%g" height="4" fill="%s"/>'
                 % (x, y, w, colour))


def svg_bars(metric, series, width=320, height=170, fixed_top=None, bands=None):
    fmt = formatter(metric)
    values = [p["value"] for p in series]
    real = [v for v in values if v > 0]
    top = fixed_top or max(values + [0])
    average = (sum(real) / len(real)) if real else 0

    parts, geo = chart_frame(width, height, top, fmt,
                             integer=(metric["kind"] == "count"), bands=bands)
    pad_l, pad_r, pad_t, plot_w, plot_h, y_of = geo

    slot = plot_w / max(len(series), 1)
    bar_w = max(6, min(34, slot - 10))

    for i, point in enumerate(series):
        y = y_of(min(point["value"], top) if top else 0)
        bar_h = max(1, pad_t + plot_h - y)
        cx = pad_l + (i + 0.5) * slot
        x = cx - bar_w / 2

        parts.append('<rect x="%g" y="%g" width="%g" height="%g" fill="%s" opacity="%s"/>'
                     % (x, pad_t + plot_h - bar_h, bar_w, bar_h, point["color"],
                        "1" if point["last"] else "0.55"))
        parts.append('<text x="%g" y="%g" class="v">%s</text>'
                     % (cx, pad_t + plot_h - bar_h - 5, esc(point["text"])))
        outcome_band(parts, x, pad_t + plot_h + 4, bar_w, point["outcome"])
        parts.append('<text x="%g" y="%g" class="x">%s</text>'
                     % (cx, height - 6, esc(point["label"])))

    if len(real) > 1 and average > 0 and not fixed_top:
        average_line(parts, geo, width, average, fmt)

    parts.append("</svg>")
    return "".join(parts)


def svg_line(metric, series, width=320, height=170):
    """Many attempts: the trajectory is the message and bars become a fence.

    Only the ends and the extremes are labelled -- eighteen numbers along a
    line is the wall of figures this was meant to replace.
    """
    fmt = formatter(metric)
    values = [p["value"] for p in series]
    real = [v for v in values if v > 0]
    top = max(values + [0])
    average = (sum(real) / len(real)) if real else 0

    parts, geo = chart_frame(width, height, top, fmt,
                             integer=(metric["kind"] == "count"))
    pad_l, pad_r, pad_t, plot_w, plot_h, y_of = geo

    slot = plot_w / max(len(series), 1)

    def x_of(i):
        return pad_l + (i + 0.5) * slot

    drawn = [(i, p) for i, p in enumerate(series) if p["value"] > 0]
    if drawn:
        points = " ".join("%g,%g" % (x_of(i), y_of(p["value"])) for i, p in drawn)
        parts.append('<polyline points="%s" class="trend"/>' % points)

    highest = max(drawn, key=lambda ip: ip[1]["value"])[0] if drawn else None
    lowest = min(drawn, key=lambda ip: ip[1]["value"])[0] if drawn else None
    labelled = {highest, lowest, drawn[0][0], drawn[-1][0]} if drawn else set()

    for i, point in drawn:
        x, y = x_of(i), y_of(point["value"])
        parts.append('<circle cx="%g" cy="%g" r="%g" fill="%s" opacity="%s"/>'
                     % (x, y, 3.5 if point["last"] else 2.5, point["color"],
                        "1" if point["last"] else "0.75"))
        if i in labelled:
            parts.append('<text x="%g" y="%g" class="v">%s</text>'
                         % (x, y - 6, esc(point["text"])))

    for i, point in enumerate(series):
        outcome_band(parts, x_of(i) - slot / 2 + 2, pad_t + plot_h + 4,
                     max(3, slot - 4), point["outcome"])

    # Every label would overlap, so only the two ends carry a time.
    if series:
        parts.append('<text x="%g" y="%g" class="x" text-anchor="start">%s</text>'
                     % (pad_l, height - 6, esc(series[0]["label"])))
        if len(series) > 1:
            parts.append('<text x="%g" y="%g" class="x" text-anchor="end">%s</text>'
                         % (width - pad_r, height - 6, esc(series[-1]["label"])))

    if len(real) > 1 and average > 0:
        average_line(parts, geo, width, average, fmt)

    parts.append("</svg>")
    return "".join(parts)


def mmss(seconds):
    seconds = int(max(0, seconds))
    return "%d:%02d" % (seconds // 60, seconds % 60)


def svg_scatter(metric, points, width=320, height=170):
    """Duration against total, where a diagonal is a constant rate.

    A total is nearly always its rate times the length of the pull. Drawn as
    bars it says what the rate chart already said; against duration it answers
    the question the bars could not -- was the big number a good pull, or a
    long one.
    """
    fmt = formatter(metric)
    tops = [p["value"] for p in points]
    top = max(tops + [0])
    longest = max([p["duration"] for p in points] + [1])

    parts, geo = chart_frame(width, height, top, fmt)
    pad_l, pad_r, pad_t, plot_w, plot_h, y_of = geo

    def x_of(duration):
        return pad_l + (duration / longest) * plot_w if longest > 0 else pad_l

    # The player's own average rate: points above it beat their usual pace.
    total = sum(p["value"] for p in points)
    seconds = sum(p["duration"] for p in points)
    if total > 0 and seconds > 0:
        rate = total / seconds
        end_y = y_of(min(rate * longest, top))
        parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="avg"/>'
                     % (pad_l, y_of(0), x_of(longest), end_y))
        parts.append('<text x="%g" y="%g" class="a">ritmo medio %s/s</text>'
                     % (width - pad_r, pad_t + 8, esc(fmt(rate))))

    for point in points:
        x, y = x_of(point["duration"]), y_of(point["value"])
        parts.append('<circle cx="%g" cy="%g" r="%g" fill="%s" opacity="%s"/>'
                     % (x, y, 4.5 if point["last"] else 3.5, point["color"],
                        "1" if point["last"] else "0.7"))
        parts.append('<circle cx="%g" cy="%g" r="1.6" fill="%s"/>'
                     % (x, y, point["outcome"]))

    parts.append('<text x="%g" y="%g" class="x" text-anchor="start">0:00</text>'
                 % (pad_l, height - 6))
    parts.append('<text x="%g" y="%g" class="x" text-anchor="end">%s</text>'
                 % (width - pad_r, height - 6, esc(mmss(longest))))
    parts.append('<text x="%g" y="%g" class="x">durata</text>'
                 % (pad_l + plot_w / 2, height - 6))

    parts.append("</svg>")
    return "".join(parts)


def svg_deaths(strips, width=320, height=170):
    """One row per attempt, from the pull's start to its end, a tick per death.

    The count of deaths is not the story: two pulls with twenty and
    twenty-three deaths were a collapse at 1:40 and a seven-minute grind, and
    the bar chart called the second one worse.
    """
    pad_l, pad_r, pad_t, clock_w = 42, 8, 18, 42
    plot_w = width - pad_l - pad_r - clock_w
    rows = max(len(strips), 1)
    row_h = min(18, (height - pad_t - 16) / rows)
    longest = max([s["duration"] for s in strips] + [1])

    parts = ['<svg viewBox="0 0 %d %d" class="chart" role="img">' % (width, height)]

    for index, strip in enumerate(strips):
        y = pad_t + index * row_h
        mid = y + row_h / 2

        # Rows are as long as the pull was, against the longest one shown.
        # Normalising each row to its own duration drew a 2:38 wipe and a 7:39
        # one at the same width, which hides the very thing the strip exists to
        # show.
        duration = strip["duration"] or 1
        row_w = max(6, plot_w * duration / longest)

        parts.append('<text x="%g" y="%g" class="t">%s</text>'
                     % (pad_l - 6, mid + 3, esc(strip["label"])))
        parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="grid"/>'
                     % (pad_l, mid, pad_l + row_w, mid))
        parts.append('<rect x="%g" y="%g" width="3" height="%g" fill="%s"/>'
                     % (pad_l + row_w, mid - row_h / 4, row_h / 2, strip["outcome"]))
        parts.append('<text x="%g" y="%g" class="t" text-anchor="start">%s</text>'
                     % (pad_l + row_w + 7, mid + 3, esc(mmss(duration))))

        def x_at(t, row_w=row_w, duration=duration):
            return pad_l + min(1.0, max(0.0, t / duration)) * row_w

        # The rest of the group, faint: a death alone says little, a death in
        # the middle of eleven others says what happened.
        for t in strip["others"]:
            parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="dother"/>'
                         % (x_at(t), mid - row_h / 3, x_at(t), mid + row_h / 3))
        for t in strip["own"]:
            parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="dself"/>'
                         % (x_at(t), mid - row_h / 2, x_at(t), mid + row_h / 2))

    parts.append('<text x="%g" y="%g" class="x" text-anchor="start">inizio</text>'
                 % (pad_l, height - 4))
    parts.append('<text x="%g" y="%g" class="x" text-anchor="end">fine pull</text>'
                 % (width - pad_r, height - 4))
    parts.append("</svg>")
    return "".join(parts)


def death_strips(fight, player_name):
    strips = []
    for i, report in enumerate(fight["reports"]):
        own, others = [], []
        for row in (report.get("players") or {}).values():
            if not isinstance(row, dict):
                continue
            when_died = num(row.get("deathTime"))
            if when_died <= 0:
                continue
            (own if row.get("name") == player_name else others).append(when_died)

        strips.append({
            "label": attempt_label(report),
            "duration": num(report.get("duration")),
            "own": sorted(own),
            "others": sorted(others),
            "outcome": KILL if report.get("result") else WIPE,
            "last": i == len(fight["reports"]) - 1,
        })
    return strips


def chart_for(fight, player_name, metric_key, players):
    metric = METRIC_BY_KEY[metric_key]
    player = players.get(player_name) or {}
    color = class_color(player) if metric["color"] == "class" else metric["color"]
    fmt = formatter(metric)
    form = CHART_FORM.get(metric_key, "auto")

    series, values = [], []
    for i, report in enumerate(fight["reports"]):
        row = (report.get("players") or {}).get(player_name)
        value = metric["get"](row) if isinstance(row, dict) else 0.0
        values.append(value)
        series.append({
            "value": value,
            "text": fmt(value),
            "label": attempt_label(report),
            "duration": num(report.get("duration")),
            "color": color,
            "outcome": KILL if report.get("result") else WIPE,
            "last": i == len(fight["reports"]) - 1,
        })

    note = ""
    if len(values) >= 2:
        state = verdict(metric, values[-2], values[-1])
        if metric["kind"] == "rate" and values[-2] > 0:
            pct = (values[-1] - values[-2]) / values[-2] * 100
            note = "%+.0f%%" % pct
        elif metric["kind"] == "count":
            note = "%+d" % int(values[-1] - values[-2])
        cls = {"better": "up", "worse": "down"}.get(state, "flat")
        note = '<span class="%s">%s</span>' % (cls, note) if note else ""

    if max(values or [0]) <= 0 and metric_key != "deaths":
        note = '<span class="flat">non rilevato</span>'

    if form == "timeline":
        strips = death_strips(fight, player_name)
        total = sum(len(s["own"]) for s in strips)
        note = '<span class="flat">%d in %d pull</span>' % (total, len(strips))
        body = svg_deaths(strips)
    elif form == "gauge":
        # 0..100 fixed, with the half below the median shaded: a percentile
        # only means anything against the whole range.
        body = svg_bars(metric, series, fixed_top=100,
                        bands=[(0, 50, "band")])
    elif form == "scatter" and any(p["duration"] > 0 for p in series):
        body = svg_scatter(metric, [p for p in series if p["value"] > 0])
    elif form == "auto" and len(series) >= LINE_FROM:
        body = svg_line(metric, series)
    else:
        body = svg_bars(metric, series)

    return ('<figure class="card"><figcaption>%s %s</figcaption>%s</figure>'
            % (esc(metric["label"]), note, body))


def compare_table(fight, metric, players):
    fmt = formatter(metric)
    reports = fight["reports"]

    names = ordered_players(fight, players, metric)

    head = ['<th class="name">Player</th>']
    for report in reports:
        colour = KILL if report.get("result") else WIPE
        head.append('<th><span style="color:%s">%s</span></th>'
                    % (colour, esc(attempt_label(report))))

    # The best value in each attempt, so a cell's bar is a share of what the
    # best player managed in that same pull rather than of the whole table.
    column_top = []
    for report in reports:
        best = 0
        for row in (report.get("players") or {}).values():
            if isinstance(row, dict):
                best = max(best, metric["get"](row))
        column_top.append(best)

    rows = []
    for name in names:
        cells = ['<td class="name" style="color:%s">%s</td>'
                 % (class_color(players[name]), esc(name))]
        previous = None
        for report_index, report in enumerate(reports):
            row = (report.get("players") or {}).get(name)
            if not isinstance(row, dict):
                cells.append('<td class="absent">assente</td>')
                previous = None
                continue

            value = metric["get"](row)
            state = verdict(metric, previous, value) if previous is not None else None
            cls = {"better": "up", "worse": "down"}.get(state, "")
            text = fmt(value)
            # The number stays; the bar behind it is what makes a column of
            # twenty-five of them scannable. Widths are shares of the best
            # value in that column, so the eye compares within an attempt.
            share = (value / column_top[report_index] * 100) if column_top[report_index] else 0
            cells.append('<td class="%s"><span class="fill" style="width:%.1f%%"></span>'
                         '<span class="n">%s</span></td>' % (cls, share, text))
            previous = value
        rows.append("<tr>%s</tr>" % "".join(cells))

    return ('<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>'
            % ("".join(head), "".join(rows)))


def container_title(box):
    """(title, tag, plain) for one section. The listing and the page have to
    agree on what a section is called, so both read it from here."""
    reports = box["reports"]
    players = {}
    for fight in box["fights"]:
        players.update(players_of(fight))
    kills = sum(1 for r in reports if r.get("result"))

    if box["kind"] == "raid":
        same_day = when(box["first"], "%d/%m") == when(box["latest"], "%d/%m")
        span = when(box["first"]) + " - " + when(
            box["latest"], "%H:%M" if same_day else "%d/%m %H:%M")
        names = [f["boss"] for f in box["fights"]]
        listed = ", ".join(names[:3])
        if len(names) > 3:
            listed += " +%d" % (len(names) - 3)
        title = "Gruppo raid &mdash; %s" % esc(span)
        detail = ("%d tentativi, %d kill / %d wipe, %d player"
                  % (len(reports), kills, len(reports) - kills, len(players)))
        tag = ("Raid &middot; %s &middot; %d tentativi &middot; %d player"
               % (esc(listed), len(reports), len(players)))
        plain = "Gruppo raid %s - %s" % (span, listed)
    else:
        # Not a player count: a key is always five, and pooling six runs made
        # with six different groups reports twenty-five, which reads as a raid
        # size and is not one. The key levels are what varies.
        levels = sorted({int(m.group(1)) for m in
                         (KEY_LEVEL.match(str(r.get("difficulty") or ""))
                          for r in reports) if m})
        keys = ""
        if levels:
            keys = (" &middot; chiave +%d" % levels[0] if len(levels) == 1
                    else " &middot; chiavi +%d..+%d" % (levels[0], levels[-1]))
        done = sum(1 for r in reports if r.get("result"))
        title = esc(box["fights"][0]["boss"])
        detail = "%d run%s, %d completate" % (
            len(reports), keys.replace(" &middot; ", ", "), done)
        tag = ("M+ &middot; %d run%s &middot; %d completate &middot; "
               "%d giocatori diversi" % (len(reports), keys, done, len(players)))
        plain = "M+ %s" % box["fights"][0]["boss"]

    return title, tag, plain, players, detail


def selector_of(box):
    """What --only matches against, besides the index."""
    if box["kind"] == "raid":
        return str(box["fights"][0]["group"] or "legacy")
    return str(box["fights"][0]["boss"])


def select_containers(containers, wanted):
    """Zero or more selectors, each an index from --list, a groupID, or part of
    a name. The union is returned in the order the sections already have, so a
    page with several dungeons in it reads chronologically rather than in the
    order they were typed."""
    if not wanted:
        return containers

    if isinstance(wanted, str):
        wanted = [wanted]

    picked, seen = [], set()
    for one in wanted:
        for box in select_one(containers, one):
            if box["key"] not in seen:
                seen.add(box["key"])
                picked.append(box)

    return [b for b in containers if b["key"] in seen]


def select_one(containers, wanted):
    needle = wanted.strip().lower()
    if needle.isdigit():
        i = int(needle)
        if 1 <= i <= len(containers):
            return [containers[i - 1]]
        raise SystemExit("--only %s: fuori intervallo, ci sono %d sezioni "
                         "(usa --list)" % (wanted, len(containers)))

    def holds_group(box):
        # An M+ container is addressed by its dungeon, but the addon may hand
        # over the groupID of one run in it -- every key is its own group. Any
        # selector the addon can produce should resolve, so a groupID that
        # belongs to any attempt in the container counts as a match.
        return any(str(r.get("groupID") or "").lower() == needle
                   for r in box["reports"])

    hits = [b for b in containers
            if needle == selector_of(b).lower()
            or needle in container_title(b)[2].lower()
            or holds_group(b)]

    if not hits:
        message = ["--only %s: nessuna sezione corrisponde." % wanted]
        if re.match(r"^\d{6,}-\d+$", needle):
            # A group id that is not in the file is almost always the run that
            # just ended: SavedVariables are written on /reload or logout, and
            # nothing before that is on disk to be read.
            message.append("Sembra l'id di un gruppo: se il tentativo e' appena "
                           "finito non e' ancora su disco.")
            message.append("Fai /reload in gioco e riprova.")
        message.append("Con --list vedi cosa c'e'.")
        raise SystemExit(" ".join(message))
    return hits


def night_table(container, metric, players):
    """Every attempt of the raid night as a column, across bosses.

    Deliberately uncoloured, unlike the per-boss tables. A rise from one boss
    to the next is not an improvement, it is a different fight: painting it
    green would invent a trend out of two unrelated encounters.
    """
    fmt = formatter(metric)
    reports = container["reports"]

    head = ['<th class="name">Player</th>']
    for report in reports:
        colour = KILL if report.get("result") else WIPE
        head.append('<th><span class="boss">%s</span><br>'
                    '<span style="color:%s">%s</span></th>'
                    % (esc(report.get("boss") or "?"), colour,
                       esc(attempt_label(report))))

    order = sorted(
        players,
        key=lambda n: (-sum(1 for r in reports
                            if isinstance((r.get("players") or {}).get(n), dict)), n),
    )

    rows = []
    for name in order:
        cells = ['<td class="name" style="color:%s">%s</td>'
                 % (class_color(players[name]), esc(name))]
        for report in reports:
            row = (report.get("players") or {}).get(name)
            if not isinstance(row, dict):
                cells.append('<td class="absent">-</td>')
                continue
            # Deaths are their own metric and their own chart; hung off the
            # end of a rate they read as part of it.
            text = fmt(metric["get"](row))
            cells.append("<td>%s</td>" % text)
        rows.append("<tr>%s</tr>" % "".join(cells))

    return ('<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>'
            % ("".join(head), "".join(rows)))


CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin:0; background:#101114; color:#e6e6e6;
       font:14px/1.45 "Segoe UI",system-ui,sans-serif; }
header { padding:18px 28px; border-bottom:1px solid #2a2c31; background:#16171b;
         display:flex; align-items:center; gap:16px; }
.mark { width:46px; height:46px; flex:0 0 46px; border-radius:50%; display:block; }
header .titles { min-width:0; }
h1 { margin:0 0 4px; font-size:20px; color:#ffd100; font-weight:600; }
.sub { color:#8b8f96; font-size:12px; }
main { padding:20px 28px 60px; }
section.fight { margin:0 0 34px; border:1px solid #2a2c31; border-radius:6px;
                background:#16171b; overflow:hidden; }
section.fight > h2 { margin:0; padding:12px 16px; font-size:16px; color:#ffd100;
                     background:#1c1e23; border-bottom:1px solid #2a2c31; font-weight:600; }
.tag { color:#8b8f96; font-weight:400; font-size:12px; margin-left:8px; }
details { border-top:1px solid #232529; }
details > summary { padding:9px 16px; cursor:pointer; color:#cfd3d8; font-size:13px;
                    user-select:none; }
details > summary:hover { background:#1c1e23; }
details > div { padding:4px 16px 16px; overflow-x:auto; }
table { border-collapse:collapse; font-size:13px; min-width:100%; }
th, td { padding:5px 10px; text-align:center; border-bottom:1px solid #232529;
         white-space:nowrap; }
th { color:#9aa0a8; font-weight:600; font-size:12px; }
td.name, th.name { text-align:left; }
td.absent { color:#5c6068; font-style:italic; }
td.up .n { color:#55dd55; } td.down .n { color:#ff5555; }
tbody td { position:relative; }
td .fill { position:absolute; left:0; top:3px; bottom:3px; border-radius:2px;
           background:rgba(255,255,255,0.07); }
td .n { position:relative; }
.grid { display:flex; flex-wrap:wrap; gap:12px; }
.card { margin:0; border:1px solid #232529; border-radius:5px; background:#131418;
        padding:8px 6px 4px; width:360px; }
.card figcaption { font-size:12px; color:#ffd100; padding:0 6px 2px; }
.card figcaption .up { color:#55dd55; } .card figcaption .down { color:#ff5555; }
.card figcaption .flat { color:#8b8f96; }
.chart { width:100%; height:auto; display:block; }
.chart .axis { stroke:#3a3d42; stroke-width:1; }
.chart .grid { stroke:#26282d; stroke-width:1; }
.chart .avg { stroke:#8b8f96; stroke-width:1; stroke-dasharray:4 3; }
.chart text.t { fill:#6f747c; font-size:8px; text-anchor:end; }
.chart text.a { fill:#8b8f96; font-size:8px; text-anchor:end; }
.chart .band { fill:rgba(255,255,255,0.035); }
.chart .trend { fill:none; stroke:#7f8792; stroke-width:1.5;
                stroke-linejoin:round; stroke-linecap:round; }
.chart .dother { stroke:#5b6068; stroke-width:1.5; }
.chart .dself { stroke:#ff5555; stroke-width:2.5; }
.chart text { fill:#9aa0a8; font-size:9px; text-anchor:middle;
              font-family:"Segoe UI",system-ui,sans-serif; }
.chart text.v { fill:#d6dae0; }
.legend { color:#8b8f96; font-size:12px; padding:10px 16px 14px; }
.player { border-top:1px solid #232529; }
.player > summary { color:#e6e6e6; }
.warn { color:#ffb454; }
th .boss { color:#6f747c; font-size:10px; font-weight:400; }
details.boss > summary { color:#ffd100; background:#1a1c21; font-weight:600; }
details.boss > div { padding:0 0 8px; }
details.boss > div > details > summary { padding-left:32px; }
"""


def render(db, sv_path, containers, total_sections=None, filter_note=""):
    history = as_list((db or {}).get("history") or {})
    shown = sum(len(b["reports"]) for b in containers)

    mtime = dt.datetime.fromtimestamp(os.path.getmtime(sv_path))
    age = dt.datetime.now() - mtime

    out = ["<!doctype html><html lang='it'><head><meta charset='utf-8'>",
           "<meta name='viewport' content='width=device-width,initial-scale=1'>",
           "<title>RaidPulse — report</title><style>%s</style></head><body>" % CSS]

    icon = icon_data_uri()
    mark = ('<img class="mark" src="%s" alt="RaidPulse">' % icon) if icon else FALLBACK_MARK

    out.append("<header>%s<div class='titles'><h1>RaidPulse — report</h1>" % mark)
    scope = "%d sezioni, %d tentativi" % (len(containers), shown)
    if total_sections and total_sections != len(containers):
        scope += (" (di %d sezioni e %d tentativi nello storico)"
                  % (total_sections, len(history)))
    out.append("<div class='sub'>%s &middot; generato %s%s</div>" %
               (scope, dt.datetime.now().strftime("%d/%m/%Y %H:%M"),
                filter_note))
    # No path: the page gets sent to other people and where the file sat on
    # one machine is noise to them. When the data is stale that still has to be
    # said, because the newest pull is only in it after a reload.
    stale = ""
    if age.total_seconds() > 3600:
        stale = (" <span class='warn'>&middot; %d ore fa: fai /reload e rigenera</span>"
                 % (age.total_seconds() // 3600))
    out.append("<div class='sub'>Dati al %s%s</div>"
               % (mtime.strftime("%d/%m/%Y %H:%M"), stale))
    out.append("</div></header><main>")

    if not containers:
        out.append("<p>Nessun report nello storico.</p>")

    for box in containers:
        reports = box["reports"]
        title, tag, _, all_players, _detail = container_title(box)

        out.append("<section class='fight'><h2>%s<span class='tag'>%s</span></h2>"
                   % (title, tag))

        # The whole night at once, which is what "every attempt of every boss
        # in this group" asks for. Raids only: a dungeon container is already
        # a single fight, so this would just repeat the table below it.
        if box["kind"] == "raid":
            for metric in METRICS:
                if not has_data(reports, metric):
                    continue
                out.append("<details%s><summary>Tutti i tentativi &mdash; %s</summary>"
                           "<div>%s</div></details>"
                           % (" open" if metric["key"] == "dps" else "",
                              esc(metric["label"]),
                              night_table(box, metric, all_players)))

        for fight in box["fights"]:
            out.append(render_fight(fight, nested=(box["kind"] == "raid")))

        out.append("<div class='legend'>Fascia sotto la colonna: verde = kill, "
                   "rossa = wipe. Colonna a piena tinta = il tentativo pi\u00f9 "
                   "recente. Verde/rosso nelle tabelle per boss = variazione oltre "
                   "il 5% rispetto al tentativo precedente (qualunque variazione "
                   "per Parse e Morti). La tabella di tutti i tentativi non \u00e8 "
                   "colorata: fra un boss e l\u2019altro una differenza non \u00e8 "
                   "un miglioramento. Le morti hanno una tabella e un grafico "
                   "propri.</div>")
        out.append("</section>")

    out.append("</main></body></html>")
    return "\n".join(out)


def has_data(reports, metric):
    """Deaths are drawn even when nobody died; everything else earns its place."""
    if metric["key"] == "deaths":
        return True
    return any(metric["get"](p) > 0
               for r in reports for p in (r.get("players") or {}).values()
               if isinstance(p, dict))


def render_fight(fight, nested=False):
    """One boss: its comparison tables and a card per player."""
    players = players_of(fight)
    reports = fight["reports"]
    out = []

    if nested:
        out.append("<details class='boss'><summary>%s <span class='tag'>%d "
                   "tentativi &middot; %d player</span></summary><div>"
                   % (esc(fight["boss"]), len(reports), len(players)))

    for metric in METRICS:
        if not has_data(reports, metric):
            continue
        out.append("<details%s><summary>Confronto &mdash; %s</summary>"
                   "<div>%s</div></details>"
                   % (" open" if (metric["key"] == "dps" and not nested) else "",
                      esc(metric["label"]), compare_table(fight, metric, players)))

    for name in ordered_players(fight, players):
        role = str(players[name].get("role") or "DAMAGER").upper()
        keys = ROLE_CHARTS.get(role, ROLE_CHARTS["DAMAGER"])
        cards = "".join(chart_for(fight, name, k, players) for k in keys)
        seen = appearances(fight, name)
        out.append(
            "<details class='player'><summary><span style='color:%s'>%s</span> "
            "&mdash; %s <span class='tag'>%d/%d tentativi</span></summary>"
            "<div class='grid'>%s</div></details>"
            % (class_color(players[name]), esc(name),
               esc(ROLE_LABEL.get(role, "DPS")), seen, len(reports), cards))

    if nested:
        out.append("</div></details>")

    return "".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sv", help="path to RaidPulse.lua (auto-detected otherwise)")
    ap.add_argument("--out", default=None,
                    help="output file (default report.html, or report-<sezione>.html "
                         "when --only picks one)")
    ap.add_argument("--list", action="store_true",
                    help="list the sections and exit, without writing anything")
    ap.add_argument("--day", metavar="GIORNO",
                    help="solo i tentativi di questo giorno: dd/mm/aaaa, dd/mm "
                         "o aaaa-mm-gg")
    ap.add_argument("--only", metavar="SEZIONE", action="append",
                    help="only this section: its number from --list, its groupID, "
                         "or part of its name. Ripetibile: --only A --only B")
    args = ap.parse_args()

    sv = args.sv or find_saved_variables()
    if not sv or not os.path.exists(sv):
        sys.exit("SavedVariables not found. Pass --sv with the path to "
                 "WTF/Account/<id>/SavedVariables/RaidPulse.lua")

    db = load_saved_variables(sv)
    history = normalise(as_list((db or {}).get("history") or {}))

    day = parse_day(args.day) if args.day else None
    if day:
        history = filter_by_day(history, day)
        if not history:
            raise SystemExit("--day %s: nessun tentativo salvato in quel giorno "
                             "(usa --list per vedere cosa c'e')" % args.day)

    containers = collect_containers(history)

    if args.list:
        print("%s — %d report, %d sezioni%s\n"
              % (sv, len(history), len(containers),
                 (" (giorno %s)" % day) if day else ""))
        for i, box in enumerate(containers, start=1):
            _, _, plain, _players, detail = container_title(box)
            print("%3d  %-46s %-38s [%s]"
                  % (i, plain[:46], detail, selector_of(box)))
        print("\nGenerane una sola:  --only <numero>   (oppure il groupID, "
              "o parte del nome)")
        return

    chosen = select_containers(containers, args.only)

    out_path = args.out
    if not out_path:
        if day and args.only:
            out_path = "report-%s.html" % day.replace("/", "-")
        elif args.only and len(chosen) == 1:
            # Short and predictable: the whole title makes a filename nobody
            # can type twice.
            box = chosen[0]
            if box["kind"] == "raid":
                base = "raid-" + when(box["first"], "%Y%m%d-%H%M")
            else:
                base = "mplus-" + str(box["fights"][0]["boss"])
            out_path = "report-%s.html" % re.sub(
                r"[^A-Za-z0-9]+", "-", base).strip("-").lower()
        else:
            out_path = "report.html"
        if day and not args.only:
            out_path = "report-%s.html" % day.replace("/", "-")

    note = ""
    if day:
        note = " &middot; giorno: %s" % esc(day)
    if args.only:
        note = note + " &middot; filtro: %s" % esc(", ".join(args.only))

    page = render(db, sv, chosen, total_sections=len(containers), filter_note=note)

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(page)

    print("Read %s (%d report)" % (sv, len(history)))
    if day:
        print("  giorno: %s" % day)
    if args.only:
        for box in chosen:
            print("  sezione: %s" % container_title(box)[2])
    print("Wrote %s (%.0f KB)" % (out_path, os.path.getsize(out_path) / 1024))

    # The addon cannot read its own absolute path, so the command it hands you
    # is relative and only works from one folder. This is the missing half:
    # run once, paste once, and from then on Esporta Report gives a command
    # that works from wherever the terminal happens to be.
    print("")
    print("In gioco, una volta sola:")
    print("  /rp toolpath %s" % os.path.abspath(__file__))


if __name__ == "__main__":
    main()
