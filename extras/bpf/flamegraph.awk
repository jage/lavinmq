# flamegraph.awk: folded stacks ("root;...;leaf count", sorted) to an SVG
# flame graph, so profiling needs nothing but bpftrace and awk on the host.
# Hover a frame for its sample count, click to zoom into it, click the
# bottom frame to zoom out. Usage:
#   sort profile.folded | awk -v title="..." -v ROOTS=1 -f flamegraph.awk > profile.svg
# ROOTS: how many bottom levels are labels (thread, fiber), not code.

BEGIN {
  W = 1200; FH = 16; PAD = 10; TOP = 40; CW = 7 # px per char at font-size 12
  for (i = 32; i < 127; i++) ORD[sprintf("%c", i)] = i
  if (title == "") title = "Flame graph"
}

function hash(s,    h, i) {
  h = 0
  for (i = 1; i <= length(s) && i <= 24; i++) h = (h * 31 + ORD[substr(s, i, 1)]) % 1000003
  return h
}

function color(name, depth,    h, r, g, b) {
  h = hash(name)
  if (name ~ /_\[k\]$/) { r = 200 + h % 55; g = 120 + h % 60; b = 40 }        # kernel
  else if (name ~ /^GC_/) { r = 60 + h % 40; g = 170 + h % 60; b = 160 + h % 50 } # libgc
  else if (name ~ /^[*~]/) { r = 205 + h % 50; g = 70 + h % 130; b = 50 + h % 30 } # Crystal
  else if (depth <= ROOTS) { r = 150 + h % 30; g = 160 + h % 30; b = 200 + h % 40 } # thread, fiber
  else { r = 190 + h % 40; g = 180 + h % 40; b = 60 + h % 40 }                    # libc etc
  return sprintf("rgb(%d,%d,%d)", r, g, b)
}

function esc(s) {
  gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); gsub(/"/, "\\&quot;", s)
  return s
}

function close_frame(d) {
  n_rect++
  r_name[n_rect] = cur[d]; r_depth[n_rect] = d; r_x[n_rect] = start[d]; r_w[n_rect] = x - start[d]
  if (d > maxdepth) maxdepth = d
}

/ [0-9]+$/ {
  count = $NF
  stack = substr($0, 1, length($0) - length(count) - 1)
  nf = split(stack, f, ";")
  c = 0
  while (c < depth_prev && c < nf && cur[c + 1] == f[c + 1]) c++
  for (d = depth_prev; d > c; d--) close_frame(d)
  for (d = c + 1; d <= nf; d++) { start[d] = x; cur[d] = f[d] }
  depth_prev = nf
  x += count
}

END {
  for (d = depth_prev; d >= 1; d--) close_frame(d)
  total = x
  if (total == 0) { print "flamegraph.awk: no samples" > "/dev/stderr"; exit 1 }
  H = TOP + (maxdepth + 1) * FH + PAD
  scale = (W - 2 * PAD) / total
  printf("<?xml version=\"1.0\" standalone=\"no\"?>\n")
  printf("<svg version=\"1.1\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" xmlns=\"http://www.w3.org/2000/svg\" font-family=\"monospace\" font-size=\"12\">\n", W, H, W, H)
  printf("<style>g.f:hover rect{stroke:#000;stroke-width:0.5;cursor:pointer} text{pointer-events:none}</style>\n")
  printf("<rect width=\"100%%\" height=\"100%%\" fill=\"#f8f8f8\"/>\n")
  printf("<text x=\"%d\" y=\"20\" font-size=\"15\" text-anchor=\"middle\">%s</text>\n", W / 2, esc(title))
  printf("<text id=\"info\" x=\"%d\" y=\"%d\"> </text>\n", PAD, H - 2)
  # bottom frame: all samples
  print_frame("all", 0, 0, total, total)
  for (i = 1; i <= n_rect; i++)
    if (r_w[i] * scale >= 0.1) print_frame(r_name[i], r_depth[i], r_x[i], r_w[i], total)
  printf("<script><![CDATA[\n%s]]></script>\n</svg>\n", js())
}

function print_frame(name, depth, fx, fw, total,    px, pw, y, label, maxc) {
  px = PAD + fx * scale; pw = fw * scale; y = H - PAD - (depth + 1) * FH
  maxc = int((pw - 6) / CW)
  label = ""
  if (maxc >= 3) label = length(name) <= maxc ? name : substr(name, 1, maxc - 2) ".."
  printf("<g class=\"f\" data-x=\"%d\" data-w=\"%d\" data-d=\"%d\" onclick=\"zoom(this)\" onmouseover=\"info(this)\">", fx, fw, depth)
  printf("<title>%s (%d samples, %.2f%%)</title>", esc(name), fw, 100 * fw / total)
  printf("<rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"%s\" rx=\"2\"/>", px, y, pw, FH - 1, color(name, depth))
  printf("<text x=\"%.1f\" y=\"%d\">%s</text></g>\n", px + 3, y + FH - 4, esc(label))
}

function js() {
  return "var W=" W ",PAD=" PAD ",CW=" CW ";\n" \
    "function info(g){document.getElementById('info').textContent=g.querySelector('title').textContent}\n" \
    "function zoom(z){var zx=+z.dataset.x,zw=+z.dataset.w,zd=+z.dataset.d,s=(W-2*PAD)/zw;\n" \
    " document.querySelectorAll('g.f').forEach(function(g){var x=+g.dataset.x,w=+g.dataset.w,d=+g.dataset.d,\n" \
    "  r=g.querySelector('rect'),t=g.querySelector('text'),n=g.querySelector('title').textContent.replace(/ \\([0-9]+ samples.*$/,'');\n" \
    "  var inside=x>=zx&&x+w<=zx+zw&&d>=zd,parent=d<zd&&x<=zx&&x+w>=zx+zw;\n" \
    "  if(!inside&&!parent){g.style.display='none';return}\n" \
    "  g.style.display='';g.style.opacity=parent?0.6:1;\n" \
    "  var px=parent?PAD:PAD+(x-zx)*s,pw=parent?W-2*PAD:w*s;\n" \
    "  r.setAttribute('x',px);r.setAttribute('width',pw);t.setAttribute('x',px+3);\n" \
    "  var m=Math.floor((pw-6)/CW);t.textContent=m<3?'':(n.length<=m?n:n.slice(0,m-2)+'..')})}\n"
}
