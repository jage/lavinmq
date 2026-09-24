# Protocol specifications

The AMQP 0-9-1 and MQTT 3.1.1 specifications as Markdown, so they can be
searched, linked and cited by section and requirement id. The text is the
specifications' own; only the layout is converted, and each keeps its
copyright notice and license.

| File | Source | License |
| --- | --- | --- |
| `mqtt-v3.1.1.md` | [OASIS Standard, HTML edition](https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html) | OASIS copyright notice, in the file's Notices section |
| `amqp0-9-1.md` | [AMQP 0-9-1 specification, PDF](https://www.rabbitmq.com/resources/specs/amqp0-9-1.pdf) | AMQP license, in the file's License section |
| `amqp0-9-1-reference.md` | [AMQP 0-9-1 XML, RabbitMQ's extended edition](https://www.rabbitmq.com/resources/specs/amqp0-9-1.extended.xml) | AMQP license, plus BSD for RabbitMQ's additions, in the file |

MQTT requirements keep their ids, e.g. `[MQTT-4.7.1-2]`. The AMQP reference
lists every class, method, field, domain and constant, with the rules and
their test scenarios; methods RabbitMQ added (`exchange.bind`,
`basic.nack`, `confirm.select` and their replies) are marked.

## Regenerating

`tools/` has the converters. They need `pandoc` and `pdftotext` (poppler).

```sh
tools/mqtt.sh mqtt-v3.1.1-os.html > mqtt-v3.1.1.md

pdftotext -layout amqp0-9-1.pdf amqp.txt
pdftotext -bbox-layout amqp0-9-1.pdf amqp.html
python3 tools/amqp_pdf.py amqp.txt amqp.html > amqp0-9-1.md

python3 tools/amqp_xml.py amqp0-9-1.extended.xml > amqp0-9-1-reference.md
```

The PDF has no paragraph markup: paragraphs come from the text blocks
poppler detects, and headings from the table of contents. Diagrams keep
their layout in code blocks, but some lose a little spacing between words.
