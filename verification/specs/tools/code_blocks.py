"""Turn runs of Word paragraphs set entirely in a monospace font (or of class
Code) into <pre> blocks."""
import html
import re
import sys

MONO = re.compile(r"font-family:\s*['\"]?(Consolas|Courier New|Courier)", re.I)
PARA = re.compile(r"<p\b[^>]*>.*?</p>", re.S)


def monospace_text(p):
    """The paragraph's text if all of it is monospace, else None."""
    if re.match(r"<p\b[^>]*class=Code", p):
        return text_of(p)
    # every non-blank text chunk must sit inside a monospace span
    depth_mono = []
    pos = 0
    ok = False
    for m in re.finditer(r"<(/?)(\w+)([^>]*)>|([^<]+)", p):
        close, tag, attrs, text = m.groups()
        if text is not None:
            t = html.unescape(text).replace("\xa0", " ")
            if t.strip():
                if not any(depth_mono):
                    return None
                ok = True
        elif tag == "span":
            if close:
                depth_mono and depth_mono.pop()
            else:
                depth_mono.append(bool(MONO.search(attrs)))
    return text_of(p) if ok else None


def text_of(p):
    t = re.sub(r"\s*\n\s*", " ", p)  # source line wraps render as a space
    t = re.sub(r"<br[^>]*>", "\n", t)
    t = re.sub(r"<[^>]+>", "", t)
    return html.unescape(t).replace("\xa0", " ").rstrip()


def convert(src):
    out = []
    pos = 0
    block = []
    last_end = 0
    for m in PARA.finditer(src):
        text = monospace_text(m.group(0))
        between = src[last_end:m.start()]
        if text is not None and (not block or not between.strip()):
            if not block:
                out.append(src[pos:m.start()])
            block.append(text)
            pos = m.end()
        else:
            if block:
                out.append(flush(block))
                block = []
            out.append(src[pos:m.end()])
            pos = m.end()
        last_end = m.end()
    if block:
        out.append(flush(block))
    out.append(src[pos:])
    return "".join(out)


def flush(lines):
    import textwrap
    body = textwrap.dedent("\n".join(lines)).strip("\n")
    return '<pre class="text">' + html.escape(body) + "</pre>\n"


sys.stdout.write(convert(sys.stdin.read()))
