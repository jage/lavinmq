
(function () {
  "use strict";
  var D = JSON.parse(document.getElementById("data").textContent);
  var GROUPS = [
    ["bdwgc 8.2.12", ["stock", "fix", "fix-pf", "fix-fl"]],
    ["upstream", ["master"]],
    ["Acton fork", ["acton", "acton-nopf", "acton-noinl", "acton-noatomicfl", "acton-noidlecv", "acton+refill8", "acton+bpm4m"]]
  ];
  var VARIANTS = [].concat.apply([], GROUPS.map(function (g) { return g[1]; }));
  var SCEN = {
    M1: ["Mark: 2M-node lists", "M1"], M2: ["Mark: pointer-free leaves", "M2"], M3: ["Mark: 6,500 parked fibers", "M3"],
    A1: ["Allocation", "A1"], AX: ["Allocation attribution", "AX, after restart"],
    B1: ["Broker at full speed", "B1"], B2: ["Idle, 2,000 connections, forced GC", "B2"],
    B3: ["Full load", "B3"], B3U: ["Full load, GC_UNMAP_THRESHOLD=1", "B3U"]
  };
  var FILTERS = [["all", "All"], ["mark", "Mark", ["M1", "M2", "M3"]], ["alloc", "Allocation", ["A1", "AX"]],
    ["b1", "Full speed", ["B1"]], ["broker", "2,000 connections", ["B2", "B3", "B3U"]]];
  var mode = "delta", filter = "all";

  function median(a) { var s = a.slice().sort(function (x, y) { return x - y; }); var n = s.length; return n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2; }
  function fmt(v) {
    if (v >= 10000) return Math.round(v).toLocaleString("en-US");
    if (v >= 100) return v.toFixed(0);
    if (v >= 10) return v.toFixed(1);
    return v.toFixed(2);
  }
  function el(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; }

  function cellInfo(row, v) {
    var vals = row.values[v]; if (!vals || !vals.length) return null;
    var base = row.values[row.base];
    var m = median(vals), lo = Math.min.apply(null, vals), hi = Math.max.apply(null, vals);
    var info = { m: m, lo: lo, hi: hi, n: vals.length, cls: "" };
    if (v === row.base) { info.cls = "base"; return info; }
    if (base && base.length) {
      var bm = median(base), blo = Math.min.apply(null, base), bhi = Math.max.apply(null, base);
      info.d = (m / bm - 1) * 100;
      var clearAbove = lo > bhi, clearBelow = hi < blo;
      if (clearAbove || clearBelow) {
        var improved = row.better === "lower" ? clearBelow : clearAbove;
        info.cls = improved ? "good" : "bad";
      }
    }
    return info;
  }

  function renderChips() {
    var box = document.getElementById("chips");
    FILTERS.forEach(function (f) {
      var b = el("button", "chip", f[1]); b.type = "button"; b.id = "filter-" + f[0];
      b.setAttribute("aria-pressed", String(f[0] === filter));
      b.addEventListener("click", function () { filter = f[0]; box.querySelectorAll("button").forEach(function (x) { x.setAttribute("aria-pressed", String(x === b)); }); renderMatrix(); });
      box.appendChild(b);
    });
  }

  function renderMatrix() {
    var t = document.getElementById("matrix"); t.textContent = "";
    var allowed = null;
    FILTERS.forEach(function (f) { if (f[0] === filter && f[2]) allowed = f[2]; });
    var rows = D.rows.filter(function (r) { return !allowed || allowed.indexOf(r.scenario) >= 0; });
    var used = VARIANTS.filter(function (v) { return rows.some(function (r) { return r.values[v] && r.values[v].length; }); });
    var thead = el("thead"), g = el("tr", "grp"), h = el("tr");
    g.appendChild(el("th", "metric", ""));
    GROUPS.forEach(function (gr) {
      var n = gr[1].filter(function (v) { return used.indexOf(v) >= 0; }).length;
      if (n) { var th = el("th", "", gr[0]); th.colSpan = n; g.appendChild(th); }
    });
    var mh = el("th", "metric", "scenario, metric"); h.appendChild(mh);
    used.forEach(function (v) { h.appendChild(el("th", "v" + (v === "fix" ? " base" : ""), v)); });
    thead.appendChild(g); thead.appendChild(h); t.appendChild(thead);
    var tb = el("tbody"), last = null;
    rows.forEach(function (r) {
      if (r.scenario !== last) {
        last = r.scenario;
        var sr = el("tr", "scen"), sc = el("td", "metric");
        sc.textContent = SCEN[r.scenario][0];
        var sp = el("span", "", SCEN[r.scenario][1]); sc.appendChild(sp);
        sr.appendChild(sc);
        var rest = el("td"); rest.colSpan = used.length; sr.appendChild(rest);
        tb.appendChild(sr);
      }
      var tr = el("tr"), mt = el("td", "metric");
      mt.appendChild(document.createTextNode(r.metric.replace(/^[^:]*: /, "") + " "));
      mt.appendChild(el("span", "u", r.unit + (r.better === "higher" ? ", higher is better" : "")));
      tr.appendChild(mt);
      used.forEach(function (v) {
        var i = cellInfo(r, v);
        if (!i) { tr.appendChild(el("td", "empty", "·")); return; }
        var td = el("td", "cell " + i.cls);
        if (mode === "delta" && v !== r.base && i.d != null) {
          td.textContent = Math.abs(i.d) < 0.5 ? "±0%" : (i.d > 0 ? "+" : "−") + Math.abs(i.d).toFixed(0) + "%";
        } else {
          td.textContent = fmt(i.m);
          if (mode === "abs" && i.n > 1) td.appendChild(el("span", "r", fmt(i.lo) + "–" + fmt(i.hi)));
        }
        td.title = v + ": median " + fmt(i.m) + " " + r.unit + ", range " + fmt(i.lo) + " to " + fmt(i.hi) + ", " + i.n + " runs";
        tr.appendChild(td);
      });
      tb.appendChild(tr);
    });
    t.appendChild(tb);
  }

  function setMode(m) {
    mode = m;
    document.getElementById("mode-delta").setAttribute("aria-pressed", String(m === "delta"));
    document.getElementById("mode-abs").setAttribute("aria-pressed", String(m === "abs"));
    renderMatrix();
  }
  document.getElementById("mode-delta").addEventListener("click", function () { setMode("delta"); });
  document.getElementById("mode-abs").addEventListener("click", function () { setMode("abs"); });

  function row(id) { for (var i = 0; i < D.rows.length; i++) if (D.rows[i].id === id) return D.rows[i]; return null; }
  function med(id, v) { var r = row(id); return r && r.values[v] ? median(r.values[v]) : null; }
  var CLS = { stock: "c-stock", fix: "c-fix", "fix-pf": "c-fixpf", "fix-fl": "c-fixfl", acton: "c-acton", master: "c-master" };

  function bars(target, groups, unit) {
    var box = document.getElementById(target);
    groups.forEach(function (gr) {
      var max = 0; gr.items.forEach(function (it) { if (it.v != null && it.v > max) max = it.v; });
      var g = el("div", "bgroup"); g.appendChild(el("div", "bt", gr.title));
      gr.items.forEach(function (it) {
        if (it.v == null) return;
        var r = el("div", "brow"); r.appendChild(el("span", "bl", it.label));
        var tr = el("div", "track"), f = el("div", "fill " + (CLS[it.key] || "c-fix"));
        f.style.width = (max ? (it.v / max) * 100 : 0).toFixed(1) + "%"; tr.appendChild(f); r.appendChild(tr);
        r.appendChild(el("span", "bv", (it.text || fmt(it.v)) + (unit ? " " + unit : ""))); g.appendChild(r);
      });
      box.appendChild(g);
    });
  }
  function items(id, vs) { return vs.map(function (v) { return { key: v, label: v, v: med(id, v) }; }); }

  bars("chart-pauses", [
    { title: "Idle, pause p50 (B2)", items: items("B2-p50", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "Idle, pause max (B2)", items: items("B2-max", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "Full load, pause p50 (B3)", items: items("B3-p50", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "Full load, pause max (B3)", items: items("B3-max", ["stock", "fix", "fix-pf", "acton"]) }
  ], "ms");
  bars("chart-rss", [
    { title: "Idle (B2)", items: items("B2-rss", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "Full load (B3)", items: items("B3-rss", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "Full load, unmap threshold 1 (B3U)", items: items("B3U-rss", ["fix", "acton"]) }
  ], "MB");
  bars("chart-b1", [
    { title: "16 B messages", items: items("B1-16-gc", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "1 KiB messages", items: items("B1-1024-gc", ["stock", "fix", "fix-pf", "acton"]) },
    { title: "libgc share of broker CPU samples, 16 B", items: [
      { key: "fix", label: "fix", v: 4.4, text: "4.4%" }, { key: "acton", label: "acton", v: 3.1, text: "3.1%" }] }
  ], "");
  (function () { // B1 rows get units added after the fact for ms/s
    document.querySelectorAll("#chart-b1 .bgroup").forEach(function (g, i) {
      if (i < 2) g.querySelectorAll(".bv").forEach(function (s) { s.textContent += " ms/s"; });
    });
  })();
  bars("chart-futex", [
    { title: "4 allocating threads", items: [
      { key: "fix", label: "fix", v: 30.9, text: "30.9%" },
      { key: "acton", label: "acton", v: 7.0, text: "7.0%" },
      { key: "fix-pf", label: "noatomicfl", v: 9.5, text: "9.5%" }] }
  ], "");

  (function lineChart() {
    var series = [["fix", "fix", "var(--text)"], ["master", "master", "var(--faint)"], ["fix-fl", "fix-fl", "var(--accent)"], ["acton", "acton", "var(--sand)"]];
    var xs = [1, 2, 4], W = 640, H = 300, L = 48, R = 120, T = 14, B = 34;
    var maxY = 0;
    series.forEach(function (s) { xs.forEach(function (t) { var v = med("AX-" + t, s[0]); if (v > maxY) maxY = v; }); });
    var top = Math.ceil(maxY / 100) * 100;
    var px = function (i) { return L + i * (W - L - R) / (xs.length - 1); };
    var py = function (v) { return T + (H - T - B) * (1 - v / top); };
    var NS = "http://www.w3.org/2000/svg";
    var svg = document.createElementNS(NS, "svg"); svg.setAttribute("viewBox", "0 0 " + W + " " + H); svg.setAttribute("class", "line");
    svg.setAttribute("role", "img"); svg.setAttribute("aria-label", "ns per step at 1, 2 and 4 threads for fix, master, fix-fl and acton");
    function add(tag, attrs, text) { var e = document.createElementNS(NS, tag); for (var k in attrs) e.setAttribute(k, attrs[k]); if (text != null) e.textContent = text; svg.appendChild(e); return e; }
    for (var y = 0; y <= top; y += 100) {
      add("line", { x1: L, x2: W - R + 10, y1: py(y), y2: py(y), "class": y === 0 ? "axis" : "grid" });
      add("text", { x: L - 8, y: py(y) + 4, "text-anchor": "end" }, String(y));
    }
    xs.forEach(function (t, i) { add("text", { x: px(i), y: H - 10, "text-anchor": "middle" }, t + (t === 1 ? " thread" : " threads")); });
    var ends = [];
    series.forEach(function (s) {
      var pts = xs.map(function (t, i) { return [px(i), py(med("AX-" + t, s[0]))]; });
      add("polyline", { points: pts.map(function (p) { return p.join(","); }).join(" "), fill: "none", stroke: s[2], "stroke-width": s[0] === "fix-fl" ? 2.5 : 1.75, "stroke-linejoin": "round" });
      pts.forEach(function (p, i) { add("circle", { cx: p[0], cy: p[1], r: i === pts.length - 1 ? 4 : 2.5, fill: s[2] }); });
      ends.push({ y: pts[pts.length - 1][1], label: s[1] + "  " + fmt(med("AX-4", s[0])) + " ns", color: s[2] });
    });
    ends.sort(function (a, b) { return a.y - b.y; });
    for (var i = 1; i < ends.length; i++) if (ends[i].y - ends[i - 1].y < 15) ends[i].y = ends[i - 1].y + 15;
    ends.forEach(function (e) { var tx = add("text", { x: px(xs.length - 1) + 10, y: e.y + 4 }, e.label); tx.style.fill = e.color; });
    document.getElementById("chart-alloc").appendChild(svg);
  })();

  (function bisect() {
    var t = document.getElementById("bisect");
    var h = el("tr"); ["step", "commit", "4 threads", "", "subject"].forEach(function (x) { h.appendChild(el("th", "", x)); }); t.appendChild(h);
    D.bisect.forEach(function (b, i) {
      var tr = el("tr", b.commit === "27c37207" ? "first" : "");
      tr.appendChild(el("td", "", String(i + 1)));
      tr.appendChild(el("td", "", b.commit));
      tr.appendChild(el("td", "", b.ns + " ns"));
      var tg = el("td"); tg.appendChild(el("span", "tag " + (b.ns > 300 ? "slow" : "fast"), b.ns > 300 ? "slow" : "fast")); tr.appendChild(tg);
      tr.appendChild(el("td", "", b.subject + (b.commit === "27c37207" ? " (first fast)" : "")));
      t.appendChild(tr);
    });
  })();

  renderChips();
  renderMatrix();
})();
