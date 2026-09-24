"""Tidy pandoc's Markdown of the MQTT 3.1.1 HTML."""
import re
import sys

md = sys.stdin.read().replace("\xa0", " ")
SELF = "https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html"

# the Word table of contents, with page numbers, is replaced by our own
start = md.index("Table of Contents")
end = re.search(r"^# 1 +Introduction$", md, flags=re.M).start()
md = md[:start] + "<!-- toc -->\n\n" + md[end:]

md = md.replace("---à", "--->").replace("ß--", "<--")             # Wingdings arrows
md = re.sub(r"!\[\]\([^)]*\)\n*", "", md)                        # logo
md = re.sub(r"\(\[\\\[email protected\\\]\]\([^)]*\)\)", "", md)  # obfuscated e-mails
md = re.sub(r"\[([^\]]+)\]\(" + re.escape(SELF) + r"#[^)]*\)", r"\1", md)  # self links
md = re.sub(r"\[([^\]]+)\]\(#_[^)]*\)", r"\1", md)                         # Word bookmarks
md = re.sub(r"\\\[(MQTT-[\d.]+-\d+)\\\]", r"[\1]", md)          # requirement ids
md = md.replace(" \\> ", " > ").replace(" \\< ", " < ")
md = re.sub(r"^(#+ [\d.]+) +", r"\1 ", md, flags=re.M)          # "# 1      Introduction"
md = re.sub(r"^#+ ((Figure|Table) [^\n]+)$", r"**\1**", md, flags=re.M)  # captions
md = re.sub(r"^(Appendix [A-Z]\.) +(.+?) *$", r"# \1 \2", md, flags=re.M)
md = re.sub(r"^(#+ .*)$", lambda m: re.sub(r"  +", " ", m.group(1)), md, flags=re.M)
md = re.sub(r"^⟦L(\d)⟧\s*", lambda m: "  " * int(m.group(1)) + "- ", md, flags=re.M)  # bullets
md = re.sub(r" ⟦L\d⟧ ", " • ", md)                                  # bullets in table cells
# tight lists: no blank line between two items
lines = md.split("\n")
item = re.compile(r"^ *- ")
md = "\n".join(
    l for i, l in enumerate(lines)
    if not (l == "" and 0 < i < len(lines) - 1 and item.match(lines[i - 1]) and item.match(lines[i + 1]))
)
md = re.sub(r"(```.*?```)|(?<!\\)\$", lambda m: m.group(1) or "\\$", md, flags=re.S)  # not math
md = re.sub(r"^\s+$", "", md, flags=re.M)
md = re.sub(r"\n{3,}", "\n\n", md)

# our own table of contents
toc = []
for level, title in re.findall(r"^(#{1,3}) ((?:\d|Appendix).+)$", md, flags=re.M):
    anchor = re.sub(r"[^\w\- ]", "", title.lower()).replace(" ", "-")  # as GitHub does
    toc.append(f"{'  ' * (len(level) - 1)}- [{title}](#{anchor})")
md = md.replace("<!-- toc -->", "## Table of Contents\n\n" + "\n".join(toc), 1)
md = re.sub(r"\AMQTT Version 3.1.1\n", "", md.strip())
header = f"""# MQTT Version 3.1.1

> Converted to Markdown from the OASIS Standard's HTML edition,
> <{SELF}>. The text is unchanged; the table of contents is regenerated
> without page numbers. The authoritative version is the .doc linked below.
"""
md = re.sub(r"[ \t]+$", "", header + md, flags=re.M)
sys.stdout.write(md + "\n")
