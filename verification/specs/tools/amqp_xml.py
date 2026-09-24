"""Generate a Markdown reference of the AMQP 0-9-1 classes, methods, fields,
domains and constants from the specification XML."""
import re
import sys
import textwrap
import xml.etree.ElementTree as ET

src = open(sys.argv[1], encoding="utf-8").read()
root = ET.fromstring(src)

# Methods RabbitMQ's edition of the XML adds to the official specification
EXTENSIONS = {
    ("confirm", "select"), ("confirm", "select-ok"),
    ("exchange", "bind"), ("exchange", "bind-ok"),
    ("exchange", "unbind"), ("exchange", "unbind-ok"),
    ("basic", "nack"),
}


def paragraphs(text):
    """Unwrap the XML's hard-wrapped text, keeping paragraph breaks."""
    text = textwrap.dedent(text or "").strip()
    return [re.sub(r"\s*\n\s*", " ", p).strip() for p in re.split(r"\n\s*\n", text) if p.strip()]


def doc_md(el, kinds=(None,)):
    out = []
    for d in el.findall("doc"):
        kind = d.get("type")
        if kind not in kinds:
            continue
        if kind == "grammar":
            out.append("```text\n" + textwrap.dedent(d.text or "").strip("\n") + "\n```")
        else:
            out.extend(paragraphs(d.text))
    return "\n\n".join(out)


def one_line(el):
    return " ".join(paragraphs(" ".join(d.text or "" for d in el.findall("doc") if d.get("type") is None)))


def cell(s):
    return s.replace("|", "\\|")


def rules_md(el, prefix):
    out = []
    for r in el.findall("rule"):
        head = f"**Rule {prefix}{r.get('name')}**"
        if r.get("on-failure"):
            head += f" (on failure: `{r.get('on-failure')}`)"
        body = doc_md(r)
        scenario = doc_md(r, kinds=("scenario",))
        part = head + "\n\n" + body
        if scenario:
            part += "\n\n" + "\n".join("> " + l if l else ">" for l in ("Test scenario: " + scenario).split("\n"))
        out.append(part)
    return "\n\n".join(out)


DOMAIN_LABELS = {d.get("name"): d.get("label", "") for d in root.findall("domain")}


def anchor(s):
    return re.sub(r"[^a-z0-9 -]", "", s.lower()).replace(" ", "-")


out = []
comments = re.findall(r"<!--(.*?)-->", src, re.S)
notice = next(c for c in comments if "Copyright Notice" in c)
modifications = next(c for c in comments if "Modified from the official" in c)

out.append(f"""# AMQP 0-9-1 Reference

> Generated from the specification XML, in the edition RabbitMQ publishes,
> <https://www.rabbitmq.com/resources/specs/amqp0-9-1.extended.xml>. It adds
> RabbitMQ's extensions to the official specification, which are marked
> "RabbitMQ extension" below. The general specification is in
> `amqp0-9-1.md`.

AMQP {root.get('major')}-{root.get('minor')}-{root.get('revision')}, default port {root.get('port')}.

## Copyright and license

```text
{textwrap.dedent(notice).strip()}
```

The XML's note on RabbitMQ's modifications:

```text
{textwrap.dedent(modifications).strip()}
```
""")

# -- constants and domains --------------------------------------------------
out.append("## Constants\n\n| Name | Value | Class | Description |\n|----|----|----|----|")
for c in root.findall("constant"):
    out.append(f"| {c.get('name')} | {c.get('value')} | {c.get('class', '')} | {cell(one_line(c))} |")

out.append("\n## Domains\n\n| Name | Type | Label | Description | Assertions |\n|----|----|----|----|----|")
for d in root.findall("domain"):
    asserts = ", ".join(
        f"{a.get('check')}" + (f" {a.get('value')}" if a.get("value") else "") for a in d.findall("assert"))
    out.append(f"| {d.get('name')} | {d.get('type')} | {d.get('label', '')} | {cell(one_line(d))} | {asserts} |")

# -- classes and methods -----------------------------------------------------
out.append("\n## Classes\n")
for c in root.findall("class"):
    out.append(f"- [{c.get('name')}](#{anchor(c.get('name'))}) ({c.get('index')}): {c.get('label')}")

for c in root.findall("class"):
    cname = c.get("name")
    out.append(f"\n## {cname}\n\nClass id {c.get('index')}: {c.get('label')}.\n")
    out.append(doc_md(c))
    grammar = doc_md(c, kinds=("grammar",))
    if grammar:
        out.append("\n" + grammar)
    chassis = ", ".join(f"{ch.get('name')} {ch.get('implement')}" for ch in c.findall("chassis"))
    out.append(f"\nImplemented by: {chassis}.")
    rules = rules_md(c, "")
    if rules:
        out.append("\n" + rules)
    props = c.findall("field")
    if props:  # content header properties, in property flag order
        out.append("\nContent properties, in property flag order:\n\n| Property | Domain | Label |\n|----|----|----|")
        for f in props:
            domain = f.get("domain") or f.get("type")
            out.append(f"| {f.get('name')} | {domain} | {f.get('label') or DOMAIN_LABELS.get(domain, '')} |")
    out.append("\n| Method | Id | Synchronous | Response | Label |\n|----|----|----|----|----|")
    for m in c.findall("method"):
        name = f"{cname}.{m.get('name')}"
        resp = ", ".join(r.get("name") for r in m.findall("response"))
        ext = " (RabbitMQ extension)" if (cname, m.get("name")) in EXTENSIONS else ""
        out.append(f"| [{name}](#{anchor(name)}) | {m.get('index')} | {'yes' if m.get('synchronous') else 'no'} | {resp} | {m.get('label', '')}{ext} |")

    for m in c.findall("method"):
        name = f"{cname}.{m.get('name')}"
        ext = "\n\n*RabbitMQ extension.*" if (cname, m.get("name")) in EXTENSIONS else ""
        out.append(f"\n### {name}\n\nMethod id {c.get('index')}.{m.get('index')}: {m.get('label', '')}.{ext}\n")
        out.append(doc_md(m))
        chassis = ", ".join(f"{ch.get('name')} {ch.get('implement')}" for ch in m.findall("chassis"))
        details = [f"Implemented by: {chassis}."]
        if m.get("synchronous"):
            resp = ", ".join(f"`{cname}.{r.get('name')}`" for r in m.findall("response"))
            details.append(f"Synchronous, responses: {resp}." if resp else "Synchronous.")
        if m.get("content"):
            details.append("Carries content.")
        out.append("\n" + " ".join(details))
        rules = rules_md(m, "")
        if rules:
            out.append("\n" + rules)
        fields = m.findall("field")
        if fields:
            out.append("\n| Field | Domain | Label |\n|----|----|----|")
            for f in fields:
                domain = f.get("domain") or f.get("type")
                label = "reserved" if f.get("reserved") else f.get("label") or DOMAIN_LABELS.get(domain, "")
                out.append(f"| {f.get('name')} | {domain} | {label} |")
            for f in fields:
                body = doc_md(f)
                rules = rules_md(f, "")
                asserts = ", ".join(
                    f"{a.get('check')}" + (f" {a.get('value')}" if a.get("value") else "") for a in f.findall("assert"))
                if body or rules or asserts:
                    out.append(f"\n#### {name} {f.get('name')}\n")
                    if body:
                        out.append(body)
                    if asserts:
                        out.append(f"\nAssertions: {asserts}.")
                    if rules:
                        out.append("\n" + rules)

md = "\n".join(out)
md = re.sub(r"\n{3,}", "\n\n", md)
md = re.sub(r"[ \t]+$", "", md, flags=re.M)
sys.stdout.write(md.strip() + "\n")
