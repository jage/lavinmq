"""Rewrite HTML tables into span-free tables with single-line cells, so pandoc
can render them as GitHub pipe tables. Merged cells keep their text in the
first cell of the span."""
import html
import re
import sys
from html.parser import HTMLParser


class TableFlattener(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.stack = []  # nested tables: list of rows, current row, current cell

    # -- helpers -----------------------------------------------------------
    def emit(self, s):
        if self.stack:
            t = self.stack[-1]
            if t["cell"] is not None:
                t["cell"]["text"].append(s)
        else:
            self.out.append(s)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "table":
            self.stack.append({"rows": [], "row": None, "cell": None})
            return
        if self.stack:
            t = self.stack[-1]
            if tag == "tr":
                t["row"] = []
                return
            if tag in ("td", "th"):
                t["cell"] = {
                    "text": [],
                    "colspan": int(a.get("colspan", "1") or 1),
                    "rowspan": int(a.get("rowspan", "1") or 1),
                    "th": tag == "th",
                }
                return
            if tag in ("p", "br", "li", "div"):
                t["cell"] is not None and t["cell"]["text"].append(" ")
                return
            return  # drop inline formatting inside cells
        self.out.append(self.get_starttag_text())

    def handle_endtag(self, tag):
        if tag == "table" and self.stack:
            t = self.stack.pop()
            rendered = self.render(t["rows"])
            if self.stack:  # a table nested in a cell: inline its text
                self.emit(" " + " ".join(rendered[1]) + " ")
            else:
                self.out.append(rendered[0])
            return
        if self.stack:
            t = self.stack[-1]
            if tag == "tr" and t["row"] is not None:
                t["rows"].append(t["row"])
                t["row"] = None
            elif tag in ("td", "th") and t["cell"] is not None:
                if t["row"] is None:
                    t["row"] = []
                t["row"].append(t["cell"])
                t["cell"] = None
            return
        self.out.append(f"</{tag}>")

    def handle_startendtag(self, tag, attrs):
        if self.stack:
            if tag == "br" and self.stack[-1]["cell"] is not None:
                self.stack[-1]["cell"]["text"].append(" ")
            return
        self.out.append(self.get_starttag_text())

    def handle_data(self, data):
        if self.stack:
            self.emit(data)
        else:
            self.out.append(html.escape(data, quote=False))

    def handle_entityref(self, name):
        self.handle_data(html.unescape(f"&{name};"))

    def handle_comment(self, data):
        if not self.stack:
            self.out.append(f"<!--{data}-->")

    def handle_decl(self, decl):
        self.out.append(f"<!{decl}>")

    # -- rendering ---------------------------------------------------------
    @staticmethod
    def clean(parts):
        s = "".join(parts).replace("\xa0", " ")
        s = re.sub(r"\s+", " ", s).strip()
        return s

    def render(self, rows):
        grid = {}
        width = 0
        for r, row in enumerate(rows):
            c = 0
            for cell in row:
                while (r, c) in grid:
                    c += 1
                text = self.clean(cell["text"])
                for dr in range(cell["rowspan"]):
                    for dc in range(cell["colspan"]):
                        grid[(r + dr, c + dc)] = text if (dr, dc) == (0, 0) else ""
                c += cell["colspan"]
                width = max(width, c)
        nrows = max((r for r, _ in grid), default=-1) + 1
        lines = [[grid.get((r, c), "") for c in range(width)] for r in range(nrows)]
        # drop empty rows and columns
        lines = [l for l in lines if any(x for x in l)]
        if lines:
            keep = [c for c in range(width) if any(l[c] for l in lines)]
            lines = [[l[c] for c in keep] for l in lines]
        # merge neighbouring columns that are never both filled in a row, which
        # is how Word misaligns merged header cells
        merged = True
        while merged and lines:
            merged = False
            for c in range(len(lines[0]) - 1):
                if all(not (l[c] and l[c + 1]) for l in lines):
                    lines = [l[:c] + [l[c] or l[c + 1]] + l[c + 2:] for l in lines]
                    merged = True
                    break
        if not lines:
            return "", []
        if len(lines) == 1 and len(lines[0]) == 1:  # a boxed paragraph
            return f"<p>{html.escape(lines[0][0])}</p>", lines[0]
        esc = lambda s: html.escape(s, quote=False)
        body = "".join(
            "<tr>" + "".join(f"<td>{esc(x)}</td>" for x in l) + "</tr>" for l in lines[1:]
        )
        head = "<tr>" + "".join(f"<th>{esc(x)}</th>" for x in lines[0]) + "</tr>"
        return f"<table><thead>{head}</thead><tbody>{body}</tbody></table>", [x for l in lines for x in l]


src = sys.stdin.read()
p = TableFlattener()
p.feed(src)
p.close()
sys.stdout.write("".join(p.out))
