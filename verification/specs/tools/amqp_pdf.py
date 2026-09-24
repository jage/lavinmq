"""Convert `pdftotext -layout` output of the AMQP 0-9-1 specification PDF to
Markdown. The text is kept as it is; only the layout is turned into Markdown:
headings (from the table of contents), paragraphs, bullet lists and code
blocks (the diagrams and grammars)."""
import re
import sys

BULLET = ""
BODY = 9          # column of body text
HEADER = re.compile(r"^\s*(Advanced Message Queuing Protocol Specification v0-9-1)?\s*(Page \d+ of \d+)?\s*$")
FOOTER = re.compile(r"^\s*Copyright \(c\) 2006-2008\. All rights reserved\. See Notice and License\..*$")

text = open(sys.argv[1], encoding="utf-8").read()


def norm(s):
    return re.sub(r"\s+", " ", s.replace(BULLET, "")).strip()


# poppler's blocks are the paragraphs: the first line of each starts one
bbox = open(sys.argv[2], encoding="utf-8").read()
PARAGRAPH_STARTS = set()
for block in re.findall(r"<block [^>]*>(.*?)</block>", bbox, re.S):
    first = re.search(r"<line [^>]*>(.*?)</line>", block, re.S)
    if first:
        words = re.findall(r">([^<]*)</word>", first.group(1))
        PARAGRAPH_STARTS.add(norm(" ".join(words)))

# -- pages: drop running headers and footers, join -------------------------
lines = []
page_starts = set()  # indexes of the first line on each page
for page in text.split("\f"):
    page_lines = [l.rstrip() for l in page.split("\n")]
    page_lines = [l for l in page_lines if not (HEADER.match(l) and l.strip()) and not FOOTER.match(l)]
    while page_lines and not page_lines[0].strip():
        page_lines.pop(0)
    while page_lines and not page_lines[-1].strip():
        page_lines.pop()
    page_starts.add(len(lines))
    lines.extend(page_lines)

# -- headings, from the table of contents -----------------------------------
toc_start = next(i for i, l in enumerate(lines) if l.strip() == "Table of Contents")
headings = {}
# the table runs over several pages, up to where the body starts
toc_end = next(i for i in range(toc_start + 1, len(lines)) if lines[i].strip() == "1 Overview")
for l in lines[toc_start + 1:toc_end]:
    m = re.match(r"^\s*(\d+(?:\.\d+)*)\s+(.*?)\.{3,}\s*\d+$", l)
    if m:
        headings[f"{m.group(1)} {m.group(2).strip()}"] = m.group(1).count(".") + 1
front, body = lines[:toc_start], lines[toc_end:]
body_page_starts = {i - toc_end for i in page_starts if i >= toc_end}
front_page_starts = {i for i in page_starts if i < toc_start}


def indent(l):
    return len(l) - len(l.lstrip(" "))


def is_heading(l, nxt=None):
    """A heading from the table of contents, or a deeper numbered one the
    table leaves out: a short numbered line that is a block of its own."""
    s = re.sub(r"\s+", " ", l.strip())
    if s in headings:
        return headings[s]
    m = re.match(r"^(\d+(?:\.\d+){3,}) [A-Z]", s)
    if m and len(s) < 80 and indent(l) == BODY and nxt is not None and starts_paragraph(nxt):
        return m.group(1).count(".") + 1
    return None


def first_word(l):
    s = l.strip()
    return s.split(" ", 1)[0] if s else ""


def looks_like_code(l):
    """Diagrams and grammars sit deeper than body text, or are aligned with
    runs of spaces, or are drawn with box characters."""
    if not l.strip() or BULLET in l:
        return False
    s = l.strip()
    return (indent(l) > BODY and indent(l) != BODY + 5) or bool(re.search(r"[+|]-{2,}|-{2,}[+|]|\S {3,}\S", s)) \
        or s.startswith("|") or s.startswith("+")


def starts_paragraph(line):
    import html
    return html.unescape(norm(line)) in PARAGRAPH_STARTS or not line.strip()


def convert(lines, page_starts=frozenset()):
    out = []
    para = []
    item = None  # current list item's text
    marker = "- "
    code = []

    def flush_para():
        nonlocal para
        if para:
            out.append(" ".join(para) + "\n")
            para = []

    def flush_item():
        nonlocal item
        if item is not None:
            out.append(marker + " ".join(item) + "\n")
            item = None

    def flush_code():
        nonlocal code
        while code and not code[-1].strip():
            code.pop()
        if code:
            cut = min(indent(l) for l in code if l.strip())
            out.append("```text\n" + "\n".join(l[cut:] for l in code) + "\n```\n")
            code = []

    for n, l in enumerate(lines):
        nxt = lines[n + 1] if n + 1 < len(lines) else ""
        s = l.strip()
        level = is_heading(l, nxt)
        if s.startswith("## "):  # headings set up by the caller
            flush_para(); flush_item(); flush_code()
            out.append("\n" + s + "\n")
            continue
        if level:
            flush_para(); flush_item(); flush_code()
            out.append("\n" + "#" * level + " " + re.sub(r"\s+", " ", s) + "\n")
            continue
        if code and (looks_like_code(l) or (not s and looks_like_code(nxt))):
            code.append(l)
            continue
        if code:
            flush_code()
        if not s:
            flush_para(); flush_item()
            out.append("")
            continue
        if s.startswith(BULLET):
            flush_para(); flush_item()
            item, marker = [s[1:].strip()], "- "
            continue
        numbered = re.match(r"^(\d+)\.\s+(\S.*)$", s)
        if numbered and indent(l) >= BODY and not level:
            flush_para(); flush_item()
            item, marker = [numbered.group(2)], f"{numbered.group(1)}. "
            continue
        if item is not None and indent(l) >= BODY + 3 and not re.search(r"\S {3,}\S|[+|]-{2,}", s):
            item.append(s)  # a wrapped item
            continue
        if looks_like_code(l):
            flush_para(); flush_item()
            code = [l]
            continue
        flush_item()
        para.append(s)
        # a paragraph goes on across a page break unless the sentence ended
        continues = n + 1 in page_starts and not re.search(r"[.:;!?)]$", s)
        if (starts_paragraph(nxt) and not continues) or is_heading(nxt):
            flush_para()
    flush_para(); flush_item(); flush_code()
    md = "\n".join(out)
    md = re.sub(r"\n{3,}", "\n\n", md)
    # a $ in prose would start inline math on GitHub
    md = re.sub(r"(```.*?```)|\$", lambda m: m.group(1) or "\\$", md, flags=re.S)
    for _ in range(2):  # tight lists
        md = re.sub(r"^((?:- |\d+\. ).*)\n\n(?=- |\d+\. )", r"\1\n", md, flags=re.M)
    return md.strip() + "\n"


# -- front matter ------------------------------------------------------------
title = "# AMQP 0-9-1 Protocol Specification"
start = next(i for i, l in enumerate(front) if l.strip() == "Technical Contributors")
notice = next(i for i, l in enumerate(front) if l.strip() == "Copyright Notice")
contributors = ["| Name | Organisation |", "|----|----|"]
for l in front[start + 1:notice]:
    for name, org in re.findall(r"(\S+(?: \S+)*?) {2,}(\S+(?: \S+)*)(?= {2,}|$)", l.strip()):
        contributors.append(f"| {name} | {org} |")
notices = [re.sub(r"^(Copyright Notice|License|Trademarks)$", r"## \1", l) for l in front[notice:]]
notice_page_starts = {i - notice for i in front_page_starts if i >= notice}
front_md = "## Technical Contributors\n\n" + "\n".join(contributors) + "\n\n" + convert(notices, notice_page_starts)

toc = "\n".join(
    "  " * (lvl - 1) + f"- [{h}](#{re.sub(r'[^\w -]', '', h.lower()).replace(' ', '-')})"
    for h, lvl in headings.items() if lvl <= 3
)

note = """> Converted to Markdown from the specification's PDF,
> <https://www.rabbitmq.com/resources/specs/amqp0-9-1.pdf>. The text is
> unchanged; the table of contents is regenerated without page numbers. The
> classes and methods are in `amqp0-9-1-reference.md`."""

md = f"{title}\n\n{note}\n\nVersion 0-9-1, 13 November 2008\n\n{front_md}\n## Table of Contents\n\n{toc}\n\n{convert(body, body_page_starts)}"
sys.stdout.write(re.sub(r"[ \t]+$", "", md, flags=re.M))
