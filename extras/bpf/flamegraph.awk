# flamegraph.awk: folded stacks ("root;...;leaf count", sorted) to an SVG
# flame graph, so profiling needs nothing but bpftrace and awk on the host.
# Hover a frame for its sample count; click it to zoom in and to show its
# details below the graph (samples, and with -v lines=FILE from lines.sh the
# source lines the samples hit); click the bottom frame to zoom out. Usage:
#   sort profile.folded | awk -v title="..." -v ROOTS=1 [-v lines=profile.lines]
#     [-v src_url=https://github.com/cloudamqp/lavinmq/blob/<commit>]
#     [-v crystal_url=https://github.com/crystal-lang/crystal/blob/<version>]
#     -f flamegraph.awk > profile.svg
# ROOTS: how many bottom levels are labels (thread, fiber), not code.
#
# Diff: with -v diff=1 the input is diff.awk's "stack before after" lines (a
# file argument, not stdin). Widths are the average of a frame's share of each
# profile, so frames of either side show; red means a larger share of the
# samples after, blue a smaller one, saturating at 4 percentage points; a
# dark outline marks frames that are in only one of the profiles.

BEGIN {
  W = 1200; FH = 16; PAD = 10; TOP = 40; CW = 7 # px per char at font-size 12
  for (i = 32; i < 127; i++) ORD[sprintf("%c", i)] = i
  if (title == "") title = "Flame graph"
  PH = 240 # details panel
  if (diff) {
    TOP = 56
    while ((getline l < ARGV[1]) > 0) { m = split(l, a, " "); T1 += a[m - 1]; T2 += a[m] }
    close(ARGV[1])
    if (T1 == 0 || T2 == 0) { print "flamegraph.awk: a profile has no samples" > "/dev/stderr"; exit 1 }
  }
  if (lines != "")
    while ((getline l < lines) > 0) {
      split(l, a, "\t")
      if (++nl[a[1]] > 15) continue # rows are sorted by samples
      LJ[a[1]] = LJ[a[1]] (LJ[a[1]] == "" ? "" : ",") "[" json(a[2]) "," json(a[3]) "," (a[4] + 0) "]"
    }
}

function json(s) {
  # \u003e too: "]]>" in a name would end the CDATA section
  gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/</, "\\u003c", s); gsub(/>/, "\\u003e", s)
  return "\"" s "\""
}

function dcolor(a, b,    d, t, r, g, bl) {
  d = b / T2 - a / T1; t = (d < 0 ? -d : d) / 0.04
  if (t > 1) t = 1
  if (d >= 0) { r = 242; g = int(238 - 150 * t); bl = int(232 - 175 * t) }
  else { r = int(236 - 180 * t); g = int(238 - 110 * t); bl = 246 }
  return sprintf("rgb(%d,%d,%d)", r, g, bl)
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
  r_a[n_rect] = xa - sa[d]; r_b[n_rect] = xb - sb[d]
  if (d > maxdepth) maxdepth = d
}

/ [0-9]+$/ {
  if (diff) {
    cb = $NF; ca = $(NF - 1)
    stack = substr($0, 1, length($0) - length(cb) - length(ca) - 2)
    count = int(0.5 + 1000000 * (ca / T1 + cb / T2) / 2)
  } else {
    count = $NF; ca = cb = 0
    stack = substr($0, 1, length($0) - length(count) - 1)
  }
  nf = split(stack, f, ";")
  c = 0
  while (c < depth_prev && c < nf && cur[c + 1] == f[c + 1]) c++
  for (d = depth_prev; d > c; d--) close_frame(d)
  for (d = c + 1; d <= nf; d++) { start[d] = x; sa[d] = xa; sb[d] = xb; cur[d] = f[d] }
  depth_prev = nf
  x += count; xa += ca; xb += cb
  self[f[nf]] += count
  split("", seen)
  for (d = 1; d <= nf; d++) if (!(f[d] in seen)) { seen[f[d]] = 1; ontot[f[d]] += count }
}

END {
  for (d = depth_prev; d >= 1; d--) close_frame(d)
  total = x
  if (total == 0) { print "flamegraph.awk: no samples" > "/dev/stderr"; exit 1 }
  GH = TOP + (maxdepth + 1) * FH + PAD # graph bottom
  H = GH + 20 + PH
  scale = (W - 2 * PAD) / total
  printf("<?xml version=\"1.0\" standalone=\"no\"?>\n")
  printf("<svg version=\"1.1\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" xmlns=\"http://www.w3.org/2000/svg\" font-family=\"monospace\" font-size=\"12\">\n", W, H, W, H)
  printf("<style>g.f:hover rect{stroke:#000;stroke-width:0.5;cursor:pointer} text{pointer-events:none}</style>\n")
  printf("<rect width=\"100%%\" height=\"100%%\" fill=\"#f8f8f8\"/>\n")
  printf("<text x=\"%d\" y=\"20\" font-size=\"15\" text-anchor=\"middle\">%s</text>\n", W / 2, esc(title))
  if (diff) printf("<text x=\"%d\" y=\"40\" text-anchor=\"middle\" fill=\"#555\">width: average share of both profiles (%d and %d samples) \xc2\xb7 <tspan fill=\"#c23b2b\">red: larger share after</tspan> \xc2\xb7 <tspan fill=\"#3561c2\">blue: smaller share after</tspan></text>\n", W / 2, T1, T2)
  printf("<text class=\"fg-info\" x=\"%d\" y=\"%d\"> </text>\n", PAD, GH + 12)
  printf("<foreignObject x=\"%d\" y=\"%d\" width=\"%d\" height=\"%d\"><div xmlns=\"http://www.w3.org/1999/xhtml\" class=\"fg-details\" style=\"font:12px monospace;color:#222;text-align:left;height:%dpx;overflow:auto;background:#fff;border:1px solid #ddd;padding:6px;box-sizing:border-box\">Click a frame for its source lines and sample counts.</div></foreignObject>\n", PAD, GH + 18, W - 2 * PAD, PH, PH)
  # bottom frame: all samples
  r_a[0] = T1; r_b[0] = T2
  print_frame("all", 0, 0, total, total, 0)
  for (i = 1; i <= n_rect; i++)
    if (r_w[i] * scale >= 0.1) print_frame(r_name[i], r_depth[i], r_x[i], r_w[i], total, i)
  printf("<script><![CDATA[\n(function () {\nvar DIFF=%d,T1=%d,T2=%d,TOTAL=%d,SRC=%s,CRYSTAL=%s,D={", diff + 0, T1, T2, total, json(src_url), json(crystal_url))
  sep = ""
  for (n in ontot) { printf("%s%s:[%d,%d,[%s]]", sep, json(n), self[n], ontot[n], LJ[n]); sep = ",\n" }
  printf("};\n%s})();\n]]></script>\n</svg>\n", js())
}

function print_frame(name, depth, fx, fw, total, i,    px, pw, y, label, maxc) {
  px = PAD + fx * scale; pw = fw * scale; y = GH - PAD - (depth + 1) * FH
  maxc = int((pw - 6) / CW)
  label = ""
  if (maxc >= 3) label = length(name) <= maxc ? name : substr(name, 1, maxc - 2) ".."
  printf("<g class=\"f\" data-x=\"%d\" data-w=\"%d\" data-d=\"%d\" data-a=\"%d\" data-b=\"%d\">", fx, fw, depth, r_a[i], r_b[i])
  if (diff)
    printf("<title>%s (before %.1f%%, after %.1f%%, %+.1f pts)</title>", esc(name), 100 * r_a[i] / T1, 100 * r_b[i] / T2, 100 * (r_b[i] / T2 - r_a[i] / T1))
  else
    printf("<title>%s (%d samples, %.2f%%)</title>", esc(name), fw, 100 * fw / total)
  printf("<rect x=\"%.1f\" y=\"%d\" width=\"%.1f\" height=\"%d\" fill=\"%s\" rx=\"2\"%s/>", px, y, pw, FH - 1,
         diff && depth > 0 ? dcolor(r_a[i], r_b[i]) : color(name, depth),
         diff && depth > 0 && (r_a[i] == 0 || r_b[i] == 0) ? " stroke=\"#222\" stroke-width=\"1.2\"" : "")
  printf("<text x=\"%.1f\" y=\"%d\">%s</text></g>\n", px + 3, y + FH - 4, esc(label))
}

function js() {
  # Scoped to its own <svg> so several graphs can share an HTML page.
  return "var W=" W ",PAD=" PAD ",CW=" CW ",S=document.currentScript,R=(S&&S.closest&&S.closest('svg'))||document.documentElement;\n" \
    "function info(g){R.querySelector('.fg-info').textContent=g.querySelector('title').textContent}\n" \
    "function h(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')}\n" \
    "function pct(n){return (100*n/TOTAL).toFixed(1)+'%'}\n" \
    "function link(loc){var m=loc.match(/^(.*):([0-9]+)$/),base=null,p;if(!m)return h(loc);\n" \
    " if(/^src\\//.test(m[1])&&SRC){base=SRC;p=m[1]}else if(/^crystal\\//.test(m[1])&&CRYSTAL){base=CRYSTAL+'/src';p=m[1].slice(8)}\n" \
    " return base?'<a target=\"_blank\" href=\"'+h(base+'/'+p+'#L'+m[2])+'\">'+h(loc)+'</a>':h(loc)}\n" \
    "function show(g){var n=g.querySelector('title').textContent.replace(/ \\((?:[0-9]+ samples|before ).*$/,''),w=+g.dataset.w,el=R.querySelector('.fg-details');\n" \
    " if(DIFF){var a=+g.dataset.a,b=+g.dataset.b,p1=100*a/T1,p2=100*b/T2,dd=p2-p1;\n" \
    "  el.innerHTML='<b>'+h(n)+'</b><br/>Before: '+a+' of '+T1+' samples ('+p1.toFixed(1)+'%)<br/>After: '+b+' of '+T2+' samples ('+p2.toFixed(1)+'%)<br/>Change: <b style=\"color:'+(dd>=0?'#c23b2b':'#3561c2')+'\">'+(dd>=0?'+':'')+dd.toFixed(1)+' percentage points</b>'+(a==0?' (only after)':b==0?' (only before)':'')+'<br/><span style=\"color:#777\">Shares are of all samples of each profile. Source lines are in the before and after flame graphs.</span>';return}\n" \
    " if(+g.dataset.d==0){el.innerHTML='All '+TOTAL+' samples. Click a frame for its source lines and sample counts.';return}\n" \
    " var d=D[n]||[0,0,[]],s='<b>'+h(n)+'</b><br/>This frame: '+w+' samples ('+pct(w)+'). In the whole profile: on the stack in '+d[1]+' samples ('+pct(d[1])+'), running itself (top of stack) in '+d[0]+' ('+pct(d[0])+').<br/>';\n" \
    " if(d[2].length){s+='Lines in this function the samples were at (a call is the line of the call):<table style=\"border-collapse:collapse;margin-top:4px\">';\n" \
    "  d[2].forEach(function(r){s+='<tr><td style=\"text-align:right;padding-right:10px\">'+r[2]+'</td><td style=\"padding-right:10px\">'+link(r[0])+'</td><td style=\"color:#777\">'+(r[1]?'inlined '+h(r[1]):'')+'</td></tr>'});s+='</table>'}\n" \
    " else s+='<span style=\"color:#777\">No source lines: kernel, libc or libgc frame, a label, or no llvm-symbolizer/addr2line where the profile was taken.</span>';\n" \
    " el.innerHTML=s}\n" \
    "function zoom(z){show(z);var zx=+z.dataset.x,zw=+z.dataset.w,zd=+z.dataset.d,s=(W-2*PAD)/zw;\n" \
    " R.querySelectorAll('g.f').forEach(function(g){var x=+g.dataset.x,w=+g.dataset.w,d=+g.dataset.d,\n" \
    "  r=g.querySelector('rect'),t=g.querySelector('text'),n=g.querySelector('title').textContent.replace(/ \\((?:[0-9]+ samples|before ).*$/,'');\n" \
    "  var inside=x>=zx&&x+w<=zx+zw&&d>=zd,parent=d<zd&&x<=zx&&x+w>=zx+zw;\n" \
    "  if(!inside&&!parent){g.style.display='none';return}\n" \
    "  g.style.display='';g.style.opacity=parent?0.6:1;\n" \
    "  var px=parent?PAD:PAD+(x-zx)*s,pw=parent?W-2*PAD:w*s;\n" \
    "  r.setAttribute('x',px);r.setAttribute('width',pw);t.setAttribute('x',px+3);\n" \
    "  var m=Math.floor((pw-6)/CW);t.textContent=m<3?'':(n.length<=m?n:n.slice(0,m-2)+'..')})}\n" \
    "R.addEventListener('click',function(e){var g=e.target.closest&&e.target.closest('g.f');if(g)zoom(g)});\n" \
    "R.addEventListener('mouseover',function(e){var g=e.target.closest&&e.target.closest('g.f');if(g)info(g)});\n" \
    "R.fgShow=show;R.fgZoom=zoom;\n"
}
