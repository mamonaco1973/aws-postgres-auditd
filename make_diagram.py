#!/usr/bin/env python3
"""Generate the README architecture diagram, one SVG per colour scheme.

Two files rather than one self-switching file: GitHub strips <style> blocks
from inline SVG, so a `prefers-color-scheme` media query inside the document is
silently dropped. The README pairs them with <picture>, which GitHub honours.

A README diagram is studied, not narrated, so it is COMPLETE rather than
minimal: both read paths (the FDW wrappers reading the log chain on every
query, and the 60-second ingest into the native table), the rotation job that
reshapes the chain, auditd and the watched directory, and the secret store.

The native path's edges are drawn DASHED: it is the conventional pipeline the
FDW is being compared against, and it runs on a timer, not per query.

Run:  python3 make_diagram.py
"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))

# ------------------------------------------------------------------------------
# Geometry and style (shared with the other projects' diagrams)
# ------------------------------------------------------------------------------
NW, NH = 420, 110                          # node width, height
GUTTER = 140                               # between columns: room for a label
MARGIN = 40
COL = [MARGIN + i * (NW + GUTTER) for i in range(3)]
ROW = [40 + i * 200 for i in range(5)]
RIGHT = 70                                 # room for the rotation edge
W = MARGIN * 2 + NW * 3 + GUTTER * 2 + RIGHT
H = ROW[3] + NH + 40
TITLE_PX, SUB_PX, EDGE_PX = 26, 17, 16

THEMES = {
    "dark": {
        "bg": "#0d1117", "panel": "#161b22", "text": "#e6edf3",
        "muted": "#8b949e", "line": "#58a6ff", "local": "#39c5bb",
        "purple": "#c39be8", "navy": "#c8d6e8", "blue": "#58a6ff",
        "amber": "#f2c163", "store": "#7ee787",
    },
    "light": {
        "bg": "#ffffff", "panel": "#f6f8fa", "text": "#1f2328",
        "muted": "#59636e", "line": "#0969da", "local": "#137e77",
        "purple": "#8250df", "navy": "#475467", "blue": "#0969da",
        "amber": "#9a6700", "store": "#1a7f37",
    },
}

# Lucide icon paths, on a 24-unit grid.
ICONS = {
    "globe": ['<circle cx="12" cy="12" r="10"/>',
              '<path d="M12 2a14.5 14.5 0 0 0 0 20 14.5 14.5 0 0 0 0-20"/>',
              '<path d="M2 12h20"/>'],
    "route": ['<circle cx="6" cy="19" r="3"/>', '<circle cx="18" cy="5" r="3"/>',
              '<path d="M12 19h4.5a3.5 3.5 0 0 0 0-7h-8a3.5 3.5 0 0 1 0-7H12"/>'],
    "network": ['<rect x="16" y="16" width="6" height="6" rx="1"/>',
                '<rect x="2" y="16" width="6" height="6" rx="1"/>',
                '<rect x="9" y="2" width="6" height="6" rx="1"/>',
                '<path d="M5 16v-3a1 1 0 0 1 1-1h12a1 1 0 0 1 1 1v3"/>',
                '<path d="M12 12V8"/>'],
    "layers": ['<path d="m12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83'
               'l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83Z"/>',
               '<path d="m22 17.65-9.17 4.16a2 2 0 0 1-1.66 0L2 17.65"/>',
               '<path d="m22 12.65-9.17 4.16a2 2 0 0 1-1.66 0L2 12.65"/>'],
    "database": ['<ellipse cx="12" cy="5" rx="9" ry="3"/>',
                 '<path d="M3 5V19A9 3 0 0 0 21 19V5"/>',
                 '<path d="M3 12A9 3 0 0 0 21 12"/>'],
    "key": ['<path d="M2.586 17.414A2 2 0 0 0 2 18.828V21a1 1 0 0 0 1 1h3a1 1 0 0 0 '
            '1-1v-1a1 1 0 0 1 1-1h1a1 1 0 0 0 1-1v-1a1 1 0 0 1 1-1h.172a2 2 0 0 0 '
            '1.414-.586l.814-.814a6.5 6.5 0 1 0-4-4z"/>',
            '<circle cx="16.5" cy="7.5" r=".5"/>'],
    "monitor": ['<rect width="20" height="14" x="2" y="3" rx="2"/>',
                '<line x1="8" x2="16" y1="21" y2="21"/>',
                '<line x1="12" x2="12" y1="17" y2="21"/>'],
    "terminal": ['<polyline points="4 17 10 11 4 5"/>',
                 '<line x1="12" x2="20" y1="19" y2="19"/>'],
    "clock": ['<circle cx="12" cy="12" r="10"/>',
              '<polyline points="12 6 12 12 16 14"/>'],
    "files": ['<path d="M15 2h-4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 2-2V8"/>',
              '<path d="M16.706 2.706A2.4 2.4 0 0 0 15 2v5a1 1 0 0 0 1 1h5'
              'a2.4 2.4 0 0 0-.706-1.706z"/>',
              '<path d="M5 7a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h8a2 2 0 0 0 1.732-1"/>'],
    "shield": ['<path d="M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 '
               '4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 '
               '1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"/>'],
    "rotate": ['<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/>',
               '<path d="M3 3v5h5"/>'],
    "folder": ['<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69'
               '-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/>'],
    "users": ['<path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/>',
              '<circle cx="9" cy="7" r="4"/>',
              '<path d="M22 21v-2a4 4 0 0 0-3-3.87"/>',
              '<path d="M16 3.13a4 4 0 0 1 0 7.75"/>'],
}

NODES = {}


def _r(nid):
    """Return (left, top, right, bottom, centre-x, centre-y) for a node."""
    x, y = NODES[nid][0], NODES[nid][1]
    return x, y, x + NW, y + NH, x + NW / 2, y + NH / 2


def gutter_x(c):
    """Centre of the gutter to the right of column c."""
    return COL[c] + NW + GUTTER / 2


def gutter_y(r):
    """Centre of the gap below row r."""
    return ROW[r] + NH + (ROW[1] - ROW[0] - NH) / 2


# ------------------------------------------------------------------------------
# Layout
# ------------------------------------------------------------------------------
# Everything below the browser and the secret runs on one EC2 instance.
# Left column: what the user touches (pgweb, the native table). Middle: the
# PostgreSQL FDW schema and the ingest timer. Right: the wrappers, the log
# chain and auditd, i.e. the files. Rotation sits top right and reaches the
# chain down the right-hand margin.
#
# id: (x, y, colour key, icon, title, subtitle[, "dashed"])
NODES.update({
    "client":   (COL[0], ROW[0], "navy", "globe", "Browser",
                 "pgweb as audit_reader"),
    "secrets":  (COL[1], ROW[0], "store", "key", "Secrets Manager",
                 "auditd-postgres-credentials"),
    "rotate":   (COL[2], ROW[0], "amber", "rotate", "audit-rotate",
                 "ingest first, gzip .1, SIGUSR1"),
    "pgweb":    (COL[0], ROW[1], "amber", "monitor", "pgweb (:80)",
                 "auditd-server, Ubuntu 26.04"),
    "fdw":      (COL[1], ROW[1], "blue", "database", "audit_fdw schema",
                 "PostgreSQL 18, file_fdw tables"),
    "wrappers": (COL[2], ROW[1], "purple", "terminal", "audit-fdw wrappers",
                 "zcat -f | ausearch, shared lock"),
    "native":   (COL[0], ROW[2], "blue", "database", "audit_native.events",
                 "PostgreSQL 18, indexed table"),
    "ingest":   (COL[1], ROW[2], "local", "clock", "audit-ingest.timer",
                 "every 60 s, checkpointed"),
    "chain":    (COL[2], ROW[2], "store", "files", "/var/log/audit",
                 "audit.log, .1, .2.gz ... .N.gz"),
    "data":     (COL[1], ROW[3], "navy", "folder", "/data",
                 "alice and bob at work"),
    "auditd":   (COL[2], ROW[3], "purple", "shield", "auditd 4.1.2",
                 "-w /data -p wa -k data_watch"),
})

cli, sec, rot, pg = _r("client"), _r("secrets"), _r("rotate"), _r("pgweb")
fdw, wr, nat, ing = _r("fdw"), _r("wrappers"), _r("native"), _r("ingest")
ch, dat, aud = _r("chain"), _r("data"), _r("auditd")
RX = rot[2] + RIGHT / 2                   # x of the right-margin lane

# id: (path, colour key, label, label_x, label_y, anchor[, "dashed"])
EDGES = {
    "e_http":   (f"M{cli[4]},{cli[3]} V{pg[1] - 5}", "line",
                 "HTTP :80", cli[4] + 14, gutter_y(0) + 6, "start"),
    "e_pw":     (f"M{sec[4]},{sec[3]} V{fdw[1] - 5}", "store",
                 "passwords at boot", sec[4] + 14, gutter_y(0) + 6, "start"),
    "e_sql":    (f"M{pg[2]},{pg[5]} H{fdw[0] - 5}", "line",
                 "localhost:5432", gutter_x(0), pg[5] - 12, "middle"),
    "e_sqln":   (f"M{pg[4]},{pg[3]} V{nat[1] - 5}", "line",
                 "SQL", pg[4] + 14, gutter_y(1) + 6, "start"),
    "e_prog":   (f"M{fdw[2]},{fdw[5]} H{wr[0] - 5}", "blue",
                 "program", gutter_x(1), fdw[5] - 12, "middle"),
    "e_read":   (f"M{wr[4]},{wr[3]} V{ch[1] - 5}", "purple",
                 "read all, oldest first", wr[4] + 14, gutter_y(1) + 6,
                 "start"),
    "e_ckpt":   (f"M{ing[2]},{ing[5]} H{ch[0] - 5}", "local",
                 "--checkpoint", gutter_x(1), ing[5] - 12, "middle",
                 "dashed"),
    "e_copy":   (f"M{ing[0]},{ing[5]} H{nat[2] + 5}", "local",
                 "COPY", gutter_x(0), ing[5] - 12, "middle",
                 "dashed"),
    "e_append": (f"M{aud[4]},{aud[1]} V{ch[3] + 5}", "purple",
                 "append", aud[4] + 14, gutter_y(2) + 6, "start"),
    "e_watch":  (f"M{dat[2]},{dat[5]} H{aud[0] - 5}", "navy",
                 "kernel events", gutter_x(1), dat[5] - 12, "middle"),
    "e_rot":    (f"M{rot[2]},{rot[5]} H{RX} V{ch[5]} H{ch[2] + 5}", "amber",
                 "rotate", RX + 4, gutter_y(0) + 6, "start"),
}

ALT = ("A browser reaches pgweb on port 80 and signs in as audit_reader. "
       "pgweb queries PostgreSQL on localhost. The audit_fdw schema's foreign "
       "tables run wrapper scripts on every query, which pipe the whole "
       "/var/log/audit chain, oldest file first, through zcat and ausearch. "
       "auditd appends kernel events for the watched /data directory to the "
       "chain. Separately, audit-ingest runs every 60 seconds, reads new "
       "events with an ausearch checkpoint and copies them into the indexed "
       "audit_native.events table. audit-rotate runs the ingest, compresses "
       "the previous file and signals auditd to start a new one. The "
       "database passwords are in Secrets Manager.")

# ------------------------------------------------------------------------------
# Rendering
# ------------------------------------------------------------------------------
FONT = "-apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial, sans-serif"


def node_svg(nid, t):
    """Render one service box: rounded panel, icon, title, subtitle."""
    x, y, key, icon, title, sub, *opt = NODES[nid]
    colour = t[key]
    dash = ' stroke-dasharray="10 7"' if opt and opt[0] == "dashed" else ""
    scale = 1.25
    isz = 24 * scale
    ix, iy = x + 20, y + (NH - isz) / 2
    tx = x + 20 + isz + 14
    return "".join([
        f'<rect x="{x}" y="{y}" width="{NW}" height="{NH}" rx="10" ry="10" '
        f'fill="{t["panel"]}" stroke="{colour}" stroke-width="2"{dash}/>',
        f'<g transform="translate({ix},{iy}) scale({scale})" fill="none" '
        f'stroke="{colour}" stroke-width="2" stroke-linecap="round" '
        f'stroke-linejoin="round">' + "".join(ICONS[icon]) + "</g>",
        f'<text x="{tx}" y="{y + NH/2 - 4}" font-family="{FONT}" '
        f'font-size="{TITLE_PX}" font-weight="600" fill="{t["text"]}">{title}</text>',
        f'<text x="{tx}" y="{y + NH/2 + 22}" font-family="{FONT}" '
        f'font-size="{SUB_PX}" fill="{t["muted"]}">{sub}</text>',
    ])


def edge_svg(eid, t):
    """Render one arrow plus its label (on a background chip, so lines that
    pass behind a label never cut through its text)."""
    d, key, label, lx, ly, anchor, *opt = EDGES[eid]
    colour = t[key]
    dash = ' stroke-dasharray="8 6"' if opt and opt[0] == "dashed" else ""
    out = (f'<path d="{d}" fill="none" stroke="{colour}" stroke-width="2"{dash} '
           f'marker-end="url(#a_{eid})"/>')
    if label:
        out += (f'<text x="{lx}" y="{ly}" text-anchor="{anchor}" '
                f'font-family="{FONT}" font-size="{EDGE_PX}" font-weight="600" '
                f'fill="{colour}" stroke="{t["bg"]}" stroke-width="6" '
                f'paint-order="stroke">{label}</text>')
    return out


def build(t):
    """Assemble the diagram for one theme."""
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
           f'viewBox="0 0 {W} {H}" role="img" aria-label="{ALT}">', "<defs>"]
    # One marker per edge: a shared marker cannot carry per-edge colour.
    for eid, spec in EDGES.items():
        out.append(
            f'<marker id="a_{eid}" viewBox="0 0 10 10" refX="9" refY="5" '
            f'markerWidth="5" markerHeight="5" orient="auto-start-reverse">'
            f'<path d="M0,0 L10,5 L0,10 z" fill="{t[spec[1]]}"/></marker>')
    out.append("</defs>")
    out.append(f'<rect width="{W}" height="{H}" fill="{t["bg"]}"/>')
    for eid in EDGES:
        out.append(edge_svg(eid, t))
    for nid in NODES:
        out.append(node_svg(nid, t))
    out.append("</svg>")
    return "".join(out)


def main():
    for name, theme in THEMES.items():
        path = os.path.join(HERE, f"architecture-{name}.svg")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(build(theme))
        print(f"  architecture-{name}.svg")


if __name__ == "__main__":
    main()
