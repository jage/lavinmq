import json, sys
d = open('data.json').read().strip().replace('</', '<\\/'); json.loads(d)
head = open('head.html').read().replace('</style>', open('part_tabs.css').read() + '</style>')
summary = open('part_summary.html').read().replace(
    'SCRATCH=$HOME/gcbench extras/gc-bench/run-viz.sh           # bpf profiles and recordings (needs root, bpftrace)',
    'SCRATCH=$HOME/gcbench extras/gc-bench/run-viz-tabs.sh      # the bpf reports in the tabs (needs root, bpftrace)')
script = open('part_script.js').read()
k = script.rstrip().rindex('})();')
script = script[:k] + open('part_tabs.js').read() + '\n' + script[k:]
tabs = [("summary", "Summary", ""), ("mark", "Marking", "M"), ("alloc", "Allocation", "A"), ("full-speed", "Full speed", "B1"),
        ("idle", "Idle, 2k connections", "B2"), ("full-load", "Full load", "B3")]
bar = '<nav class="tabbar" aria-label="Report sections"><div class="tabbar-in" role="tablist">' + ''.join(
    f'<button type="button" class="tab" role="tab" id="tab-{t}" aria-controls="panel-{t}" aria-selected="{str(t=="summary").lower()}">{n}{" <small>"+s+"</small>" if s else ""}</button>'
    for t, n, s in tabs) + '</div></nav>'
page = (head + '<div class="wrap top-wrap">' + open('part_header.html').read() + '</div>\n' + bar +
        '\n<div class="wrap sum-wrap panel" id="panel-summary" role="tabpanel" aria-labelledby="tab-summary">\n' + summary + '</div>\n' +
        open('part_tabs.html').read().replace('<section class="panel wide-wrap"', '<section role="tabpanel" class="panel wide-wrap"') +
        '\n<script id="data" type="application/json">' + d + '</script>\n<script>' + script + '</script>\n')
open('acton-bdwgc.html', 'w').write(page)
print(len(page))
