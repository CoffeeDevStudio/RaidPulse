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
import datetime as dt
import glob
import html
import os
import re
import sys

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


def as_list(table):
    """A Lua array comes back as {1: v, 2: v}; give it back in order."""
    if not isinstance(table, dict):
        return []
    keys = [k for k in table if isinstance(k, int)]
    return [table[k] for k in sorted(keys)]


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
    {"key": "taken",   "label": "Damage Taken",   "kind": "rate",  "better": 0,
     "get": lambda p: _first(p, "blizzardDamageTaken", "damageTaken"), "color": "#e67e22"},
    {"key": "parse",   "label": "Parse",          "kind": "count", "better": 1,
     "get": lambda p: num(p.get("mcaRating")), "color": "#c74ffb"},
    {"key": "deaths",  "label": "Morti",          "kind": "count", "better": -1,
     "get": lambda p: num(p.get("deaths")), "color": "#c0392b"},
]
METRIC_BY_KEY = {m["key"]: m for m in METRICS}

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


def svg_chart(metric, series, width=320, height=150):
    """A column chart in inline SVG: no script, no external asset, prints."""
    pad_l, pad_b, pad_t = 6, 34, 18
    plot_h = height - pad_b - pad_t
    inner_w = width - pad_l * 2
    top = max([abs(p["value"]) for p in series] + [0])

    slot = inner_w / max(len(series), 1)
    bar_w = max(6, min(34, slot - 10))

    parts = ['<svg viewBox="0 0 %d %d" class="chart" role="img">' % (width, height)]
    parts.append('<line x1="%g" y1="%g" x2="%g" y2="%g" class="axis"/>'
                 % (pad_l, pad_t + plot_h, width - pad_l, pad_t + plot_h))

    for i, point in enumerate(series):
        bar_h = 1 if top <= 0 else max(1, point["value"] / top * plot_h)
        cx = pad_l + (i + 0.5) * slot
        x = cx - bar_w / 2
        y = pad_t + plot_h - bar_h

        parts.append('<rect x="%g" y="%g" width="%g" height="%g" fill="%s" opacity="%s"/>'
                     % (x, y, bar_w, bar_h, point["color"], "1" if point["last"] else "0.55"))
        parts.append('<text x="%g" y="%g" class="v">%s</text>'
                     % (cx, y - 4, esc(point["text"])))
        # the outcome band, the same signal the addon draws under each column
        parts.append('<rect x="%g" y="%g" width="%g" height="4" fill="%s"/>'
                     % (x, pad_t + plot_h + 4, bar_w, point["outcome"]))
        parts.append('<text x="%g" y="%g" class="x">%s</text>'
                     % (cx, height - 6, esc(point["label"])))

    parts.append("</svg>")
    return "".join(parts)


def chart_for(fight, player_name, metric_key, players):
    metric = METRIC_BY_KEY[metric_key]
    player = players.get(player_name) or {}
    color = class_color(player) if metric["color"] == "class" else metric["color"]
    fmt = formatter(metric)

    series, values = [], []
    for i, report in enumerate(fight["reports"]):
        row = (report.get("players") or {}).get(player_name)
        value = metric["get"](row) if isinstance(row, dict) else 0.0
        values.append(value)
        series.append({
            "value": value,
            "text": fmt(value),
            "label": attempt_label(report),
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

    return ('<figure class="card"><figcaption>%s %s</figcaption>%s</figure>'
            % (esc(metric["label"]), note, svg_chart(metric, series)))


def compare_table(fight, metric, players):
    fmt = formatter(metric)
    reports = fight["reports"]

    names = ordered_players(fight, players, metric)

    head = ['<th class="name">Player</th>']
    for report in reports:
        colour = KILL if report.get("result") else WIPE
        head.append('<th><span style="color:%s">%s</span></th>'
                    % (colour, esc(attempt_label(report))))

    rows = []
    for name in names:
        cells = ['<td class="name" style="color:%s">%s</td>'
                 % (class_color(players[name]), esc(name))]
        previous = None
        for report in reports:
            row = (report.get("players") or {}).get(name)
            if not isinstance(row, dict):
                cells.append('<td class="absent">assente</td>')
                previous = None
                continue
            value = metric["get"](row)
            state = verdict(metric, previous, value) if previous is not None else None
            cls = {"better": "up", "worse": "down"}.get(state, "")
            text = fmt(value)
            if metric["kind"] == "rate" and num(row.get("deaths")) > 0:
                text += " +%d" % int(num(row["deaths"]))
            cells.append('<td class="%s">%s</td>' % (cls, text))
            previous = value
        rows.append("<tr>%s</tr>" % "".join(cells))

    return ('<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>'
            % ("".join(head), "".join(rows)))


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
            text = fmt(metric["get"](row))
            if metric["kind"] == "rate" and num(row.get("deaths")) > 0:
                text += " +%d" % int(num(row["deaths"]))
            cells.append("<td>%s</td>" % text)
        rows.append("<tr>%s</tr>" % "".join(cells))

    return ('<table><thead><tr>%s</tr></thead><tbody>%s</tbody></table>'
            % ("".join(head), "".join(rows)))


CSS = """
:root { color-scheme: dark; }
* { box-sizing: border-box; }
body { margin:0; background:#101114; color:#e6e6e6;
       font:14px/1.45 "Segoe UI",system-ui,sans-serif; }
header { padding:20px 28px; border-bottom:1px solid #2a2c31; background:#16171b; }
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
td.up { color:#55dd55; } td.down { color:#ff5555; }
.grid { display:flex; flex-wrap:wrap; gap:12px; }
.card { margin:0; border:1px solid #232529; border-radius:5px; background:#131418;
        padding:8px 6px 4px; width:340px; }
.card figcaption { font-size:12px; color:#ffd100; padding:0 6px 2px; }
.card figcaption .up { color:#55dd55; } .card figcaption .down { color:#ff5555; }
.card figcaption .flat { color:#8b8f96; }
.chart { width:100%; height:auto; display:block; }
.chart .axis { stroke:#3a3d42; stroke-width:1; }
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


def render(db, sv_path):
    history = as_list((db or {}).get("history") or {})
    containers = collect_containers(history)

    mtime = dt.datetime.fromtimestamp(os.path.getmtime(sv_path))
    age = dt.datetime.now() - mtime

    out = ["<!doctype html><html lang='it'><head><meta charset='utf-8'>",
           "<meta name='viewport' content='width=device-width,initial-scale=1'>",
           "<title>RaidPulse — report</title><style>%s</style></head><body>" % CSS]

    out.append("<header><h1>RaidPulse — report</h1>")
    out.append("<div class='sub'>%d sezioni, %d tentativi salvati &middot; "
               "generato %s</div>" %
               (len(containers), len(history),
                dt.datetime.now().strftime("%d/%m/%Y %H:%M")))
    out.append("<div class='sub'>Origine: %s &middot; scritto %s%s</div>" % (
        esc(sv_path), mtime.strftime("%d/%m/%Y %H:%M"),
        (" <span class='warn'>(%d ore fa: fai /reload per aggiornarlo)</span>"
         % (age.total_seconds() // 3600)) if age.total_seconds() > 3600 else ""))
    out.append("</header><main>")

    if not containers:
        out.append("<p>Nessun report nello storico.</p>")

    for box in containers:
        reports = box["reports"]
        all_players = {}
        for fight in box["fights"]:
            all_players.update(players_of(fight))

        if box["kind"] == "raid":
            same_day = when(box["first"], "%d/%m") == when(box["latest"], "%d/%m")
            span = when(box["first"]) + " - " + when(
                box["latest"], "%H:%M" if same_day else "%d/%m %H:%M")
            title = "Gruppo raid &mdash; %s" % esc(span)
            # The bosses by name, not just how many: a night is remembered by
            # what it was spent on.
            names = [f["boss"] for f in box["fights"]]
            listed = ", ".join(names[:3])
            if len(names) > 3:
                listed += " +%d" % (len(names) - 3)
            tag = ("Raid &middot; %s &middot; %d tentativi &middot; %d player"
                   % (esc(listed), len(reports), len(all_players)))
        else:
            title = esc(box["fights"][0]["boss"])
            tag = ("M+ &middot; %d run &middot; tutte le chiavi e i gruppi "
                   "&middot; %d player" % (len(reports), len(all_players)))

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
                   "un miglioramento. &quot;+N&quot; = morti.</div>")
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
    ap.add_argument("--out", default="report.html", help="output file")
    args = ap.parse_args()

    sv = args.sv or find_saved_variables()
    if not sv or not os.path.exists(sv):
        sys.exit("SavedVariables not found. Pass --sv with the path to "
                 "WTF/Account/<id>/SavedVariables/RaidPulse.lua")

    db = load_saved_variables(sv)
    page = render(db, sv)

    with open(args.out, "w", encoding="utf-8") as fh:
        fh.write(page)

    history = as_list((db or {}).get("history") or {})
    print("Read %s (%d report)" % (sv, len(history)))
    print("Wrote %s (%.0f KB)" % (args.out, os.path.getsize(args.out) / 1024))


if __name__ == "__main__":
    main()
