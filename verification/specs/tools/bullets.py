"""Mark Word bullet paragraphs with their nesting level, from the left margin
relative to the other bullets in the same run, as ⟦L<level>⟧."""
import re
import sys

PARA = re.compile(r"<p\b([^>]*)>(.*?)</p>", re.S)
SYMBOL_BULLET = re.compile(
    r"^\s*<span[^>]*font-family:Symbol[^>]*>·(?:<span[^>]*>(?:&nbsp;|\s)*</span>)?</span>", re.S)


def margin_pt(attrs):
    m = re.search(r"margin-left:\s*([-\d.]+)(in|pt|cm)", attrs)
    if not m:
        return 18.0  # Word's default list indent
    v, unit = float(m.group(1)), m.group(2)
    return v * {"in": 72, "pt": 1, "cm": 28.35}[unit]


def bullet(attrs, body):
    if SYMBOL_BULLET.match(body):
        return SYMBOL_BULLET.sub("", body, 1)
    if "class=MsoListBullet" in attrs:
        return body
    return None


src = sys.stdin.read()
paras = list(PARA.finditer(src))
out, pos = [], 0
i = 0
while i < len(paras):
    run = []
    j = i
    while j < len(paras):
        m = paras[j]
        b = bullet(m.group(1), m.group(2))
        gap = src[paras[j - 1].end():m.start()] if run else ""
        if b is None or (run and gap.strip()):
            break
        run.append((m, b))
        j += 1
    if not run:
        i += 1
        continue
    levels = sorted({margin_pt(m.group(1)) for m, _ in run})
    for m, body in run:
        out.append(src[pos:m.start()])
        level = levels.index(margin_pt(m.group(1)))
        out.append(f"<p>⟦L{level}⟧ {body}</p>")
        pos = m.end()
    i = j
out.append(src[pos:])
sys.stdout.write("".join(out))
