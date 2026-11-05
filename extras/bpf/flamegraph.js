// flamegraph.js: the script flamegraph.awk embeds in each SVG, after
// "var DIFF, T1, T2, TOTAL, SRC, CRYSTAL, D, W, PAD, CW". Scoped to its own
// <svg> so several graphs can share an HTML page. It goes in a CDATA
// section, so it must never contain the three characters that end one.
//
// Frames are <g class="f"> with data-x, data-w (samples), data-d (depth)
// and, in a diff, data-a and data-b (samples before and after). A frame's
// samples are the range [x, x + w): a frame's range holds its callees'.
var S = document.currentScript, R = (S && S.closest && S.closest('svg')) || document.documentElement;
var FRAMES = Array.prototype.slice.call(R.querySelectorAll('g.f'));
FRAMES.forEach(function (g) {
  g.dataset.ox = g.dataset.x; g.dataset.ow = g.dataset.w;
  g.dataset.fill = g.querySelector('rect').getAttribute('fill');
});
var BOTTOM = FRAMES.filter(function (g) { return +g.dataset.d == 0; })[0];
var MATCH = null; // the active filter, a RegExp

function name(g) { return g.querySelector('title').textContent.replace(/ \((?:[0-9]+ samples|before ).*$/, ''); }
function info(g) { R.querySelector('.fg-info').textContent = g.querySelector('title').textContent; }
function h(s) { return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;'); }
function pct(n) { return (100 * n / TOTAL).toFixed(1) + '%'; }
function link(loc) {
  var m = loc.match(/^(.*):([0-9]+)$/), base = null, p;
  if (!m) return h(loc);
  if (/^src\//.test(m[1]) && SRC) { base = SRC; p = m[1]; }
  else if (/^crystal\//.test(m[1]) && CRYSTAL) { base = CRYSTAL + '/src'; p = m[1].slice(8); }
  return base ? '<a target="_blank" href="' + h(base + '/' + p + '#L' + m[2]) + '">' + h(loc) + '</a>' : h(loc);
}

function show(g) {
  var n = name(g), w = +g.dataset.ow, el = R.querySelector('.fg-details');
  if (+g.dataset.d == 0 && MATCH) { summary(); return; }
  if (DIFF) {
    var a = +g.dataset.a, b = +g.dataset.b, p1 = 100 * a / T1, p2 = 100 * b / T2, dd = p2 - p1;
    el.innerHTML = '<b>' + h(n) + '</b><br/>Before: ' + a + ' of ' + T1 + ' samples (' + p1.toFixed(1) + '%)<br/>After: ' + b + ' of ' + T2 + ' samples (' + p2.toFixed(1) + '%)<br/>Change: <b style="color:' + (dd >= 0 ? '#c23b2b' : '#3561c2') + '">' + (dd >= 0 ? '+' : '') + dd.toFixed(1) + ' percentage points</b>' + (a == 0 ? ' (only after)' : b == 0 ? ' (only before)' : '') + '<br/><span style="color:#777">Shares are of all samples of each profile. Source lines are in the before and after flame graphs.</span>';
    return;
  }
  if (+g.dataset.d == 0) {
    el.innerHTML = 'All ' + TOTAL + ' samples. Click a frame for its source lines and sample counts.';
    return;
  }
  var d = D[n] || [0, 0, []], s = '<b>' + h(n) + '</b><br/>This frame: ' + w + ' samples (' + pct(w) + '). In the whole profile: on the stack in ' + d[1] + ' samples (' + pct(d[1]) + '), running itself (top of stack) in ' + d[0] + ' (' + pct(d[0]) + ').<br/>';
  if (d[2].length) {
    s += 'Lines in this function the samples were at (a call is the line of the call):<table style="border-collapse:collapse;margin-top:4px">';
    d[2].forEach(function (r) { s += '<tr><td style="text-align:right;padding-right:10px">' + r[2] + '</td><td style="padding-right:10px">' + link(r[0]) + '</td><td style="color:#777">' + (r[1] ? 'inlined ' + h(r[1]) : '') + '</td></tr>'; });
    s += '</table>';
  } else s += '<span style="color:#777">No source lines: kernel, libc or libgc frame, a label, or no llvm-symbolizer/addr2line where the profile was taken.</span>';
  el.innerHTML = s;
}

function zoom(z) {
  show(z);
  var zx = +z.dataset.x, zw = +z.dataset.w, zd = +z.dataset.d, s = (W - 2 * PAD) / zw;
  FRAMES.forEach(function (g) {
    var x = +g.dataset.x, w = +g.dataset.w, d = +g.dataset.d, r = g.querySelector('rect'), t = g.querySelector('text'), n = name(g);
    var inside = x >= zx && x + w <= zx + zw && d >= zd, parent = d < zd && x <= zx && x + w >= zx + zw;
    if (w == 0 || (!inside && !parent)) { g.style.display = 'none'; return; }
    g.style.display = ''; g.style.opacity = parent ? 0.6 : 1;
    var px = parent ? PAD : PAD + (x - zx) * s, pw = parent ? W - 2 * PAD : w * s;
    r.setAttribute('x', px); r.setAttribute('width', pw); t.setAttribute('x', px + 3);
    var m = Math.floor((pw - 6) / CW);
    t.textContent = m < 3 ? '' : (n.length <= m ? n : n.slice(0, m - 2) + '..');
  });
}

// Filter. Matching frames turn magenta. With "only matching stacks", the
// samples kept are the union of the matching frames' ranges, every frame
// shrinks to its part of that union, and the graph is laid out again.
var KEPT = []; // merged [start, end) ranges of the kept samples
function kept(a, b) { // kept samples in [a, b)
  var n = 0;
  KEPT.forEach(function (k) { var s = Math.max(a, k[0]), e = Math.min(b, k[1]); if (e > s) n += e - s; });
  return n;
}
function outermost(ms) { // matching frames not inside another matching frame
  ms = ms.slice().sort(function (p, q) { return (+p.dataset.ox - +q.dataset.ox) || (+p.dataset.d - +q.dataset.d); });
  var out = [], end = -1;
  ms.forEach(function (g) { var x = +g.dataset.ox; if (x >= end) { out.push(g); end = x + +g.dataset.ow; } });
  return out;
}
function summary() {
  var el = R.querySelector('.fg-details'), top = outermost(FRAMES.filter(function (g) { return g.dataset.m == '1'; }));
  var n = 0, a = 0, b = 0;
  top.forEach(function (g) { n += +g.dataset.ow; a += +g.dataset.a; b += +g.dataset.b; });
  var s = '<b>' + h(MATCH.source) + '</b> is on the stack in ' + (DIFF ? (100 * a / T1).toFixed(1) + '% of the samples before and ' + (100 * b / T2).toFixed(1) + '% after' : n + ' of ' + TOTAL + ' samples (' + pct(n) + ')') + '.';
  var rows = Object.keys(D).filter(function (k) { return MATCH.test(k); }).sort(function (p, q) { return D[q][1] - D[p][1]; });
  if (rows.length) {
    s += ' Matching functions' + (rows.length > 40 ? ', top 40 of ' + rows.length : '') + ':<table style="border-collapse:collapse;margin-top:4px"><tr style="color:#777"><td style="text-align:right;padding-right:10px">on the stack</td><td style="text-align:right;padding-right:10px">running itself</td><td></td></tr>';
    rows.slice(0, 40).forEach(function (k) { s += '<tr><td style="text-align:right;padding-right:10px">' + pct(D[k][1]) + '</td><td style="text-align:right;padding-right:10px">' + pct(D[k][0]) + '</td><td>' + h(k) + '</td></tr>'; });
    s += '</table>';
  }
  if (DIFF) s += '<span style="color:#777">In a diff the per-function shares are of both profiles together.</span>';
  el.innerHTML = s;
}
function filter() {
  var q = R.querySelector('.fg-q').value, only = R.querySelector('.fg-only').checked, msg = R.querySelector('.fg-msg');
  MATCH = null; msg.textContent = '';
  if (q) { try { MATCH = new RegExp(q); } catch (e) { msg.textContent = 'not a regex'; } }
  FRAMES.forEach(function (g) {
    var m = MATCH && +g.dataset.d > 0 && MATCH.test(name(g));
    g.dataset.m = m ? '1' : '';
    g.querySelector('rect').setAttribute('fill', m ? 'rgb(225,0,225)' : g.dataset.fill);
  });
  KEPT = [];
  if (MATCH && only) {
    outermost(FRAMES.filter(function (g) { return g.dataset.m == '1'; })).forEach(function (g) { KEPT.push([+g.dataset.ox, +g.dataset.ox + +g.dataset.ow]); });
    if (!KEPT.length) msg.textContent = 'no frame matches';
  }
  FRAMES.forEach(function (g) {
    var x = +g.dataset.ox, w = +g.dataset.ow;
    if (KEPT.length) { g.dataset.x = kept(0, x); g.dataset.w = kept(x, x + w); }
    else { g.dataset.x = x; g.dataset.w = w; }
  });
  zoom(BOTTOM);
}

var bar = R.querySelector('.fg-bar');
[['GC', /^(GC_|GC-marker|\*GC::)/], ['Allocation', /^(GC_malloc|GC_generic_malloc|GC_realloc|GC_alloc_large|\*GC::(malloc|realloc))/],
 ['Syscalls', /^__(x64|arm64)_sys_\w+_\[k\]$/], ['Kernel', /_\[k\]$/], ['Locks', /futex|pthread_(mutex|cond|rwlock)|Mutex|SpinLock|spin_lock/],
 ['Fiber switches', /swapcontext|Scheduler#(run_loop|find_next_runnable|resume)/], ['Event loop', /EventLoop|epoll/]].forEach(function (p) {
  var b = document.createElementNS('http://www.w3.org/1999/xhtml', 'button');
  b.textContent = p[0]; b.title = p[1].source; b.style.cssText = 'font:12px monospace;padding:2px 6px;cursor:pointer';
  b.addEventListener('click', function () { R.querySelector('.fg-q').value = p[1].source; filter(); });
  bar.insertBefore(b, R.querySelector('.fg-clear'));
});
R.querySelector('.fg-q').addEventListener('keydown', function (e) { if (e.key == 'Enter') filter(); });
R.querySelector('.fg-q').addEventListener('change', filter);
R.querySelector('.fg-only').addEventListener('change', filter);
R.querySelector('.fg-clear').addEventListener('click', function () { R.querySelector('.fg-q').value = ''; filter(); });
R.addEventListener('click', function (e) { var g = e.target.closest && e.target.closest('g.f'); if (g) zoom(g); });
R.addEventListener('mouseover', function (e) { var g = e.target.closest && e.target.closest('g.f'); if (g) info(g); });
R.fgShow = show; R.fgZoom = zoom; R.fgFilter = function (q, only) {
  R.querySelector('.fg-q').value = q || ''; if (only !== undefined) R.querySelector('.fg-only').checked = only; filter();
};
