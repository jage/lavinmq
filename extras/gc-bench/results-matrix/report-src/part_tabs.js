
  // ---- Scenario tables in the tabs: median with the change against fix under it ----
  function renderMini(t) {
    var scen = t.getAttribute("data-scenarios").split(" ");
    var rows = D.rows.filter(function (r) { return scen.indexOf(r.scenario) >= 0; });
    var used = VARIANTS.filter(function (v) { return rows.some(function (r) { return r.values[v] && r.values[v].length; }); });
    var thead = el("thead"), h = el("tr");
    h.appendChild(el("th", "metric", "metric"));
    used.forEach(function (v) { h.appendChild(el("th", "v" + (v === "fix" ? " base" : ""), v)); });
    thead.appendChild(h); t.appendChild(thead);
    var tb = el("tbody"), last = null;
    rows.forEach(function (r) {
      if (scen.length > 1 && r.scenario !== last) {
        last = r.scenario;
        var sr = el("tr", "scen"), sc = el("td", "metric", SCEN[r.scenario][0]); sr.appendChild(sc);
        var rest = el("td"); rest.colSpan = used.length; sr.appendChild(rest); tb.appendChild(sr);
      }
      var tr = el("tr"), mt = el("td", "metric");
      mt.appendChild(document.createTextNode(r.metric.replace(/^[^:]*: /, "") + " "));
      mt.appendChild(el("span", "u", r.unit));
      tr.appendChild(mt);
      used.forEach(function (v) {
        var i = cellInfo(r, v);
        if (!i) { tr.appendChild(el("td", "empty", "·")); return; }
        var td = el("td", "cell " + i.cls, fmt(i.m));
        if (v !== r.base && i.d != null)
          td.appendChild(el("span", "r", Math.abs(i.d) < 0.5 ? "±0%" : (i.d > 0 ? "+" : "−") + Math.abs(i.d).toFixed(0) + "%"));
        td.title = v + ": median " + fmt(i.m) + " " + r.unit + ", range " + fmt(i.lo) + " to " + fmt(i.hi) + ", " + i.n + " runs";
        tr.appendChild(td);
      });
      tb.appendChild(tr);
    });
    t.appendChild(tb);
  }
  document.querySelectorAll("table.mini").forEach(renderMini);

  // ---- The lavinmq-bpf reports, one per scenario tab, loaded on first view ----
  function themeOf() { return document.documentElement.getAttribute("data-theme"); }
  function syncTheme(frame) {
    try {
      var root = frame.contentDocument && frame.contentDocument.documentElement; if (!root) return;
      var t = themeOf();
      if (t) root.setAttribute("data-theme", t); else root.removeAttribute("data-theme");
      frame.contentWindow.dispatchEvent(new Event("resize"));
    } catch (e) {}
  }
  function fitFrame(frame) {
    try {
      var doc = frame.contentDocument; if (!doc || !doc.body) return;
      var fit = function () {
        var h = Math.max(doc.documentElement.scrollHeight, doc.body.scrollHeight);
        if (h > 0) frame.style.height = h + "px";
      };
      fit();
      if (window.ResizeObserver) new ResizeObserver(fit).observe(doc.body);
    } catch (e) {}
  }
  function loadReport(panel) {
    var box = panel.querySelector(".report"); if (box.getAttribute("data-loaded")) return;
    box.setAttribute("data-loaded", "1");
    var name = panel.getAttribute("data-report"), url = "viz/" + name + ".html";
    var bar = el("div", "rbar");
    bar.appendChild(el("span", "eyebrow", "lavinmq-bpf report"));
    var status = el("span", "muted small", "Loading the report…"); bar.appendChild(status);
    var a = el("a", "small", "Open in a new tab ->"); a.href = url; a.target = "_blank"; a.rel = "noopener"; bar.appendChild(a);
    box.appendChild(bar);
    var frame = el("iframe"); frame.title = "lavinmq-bpf report: " + name; frame.setAttribute("allow", "fullscreen");
    frame.setAttribute("loading", "eager"); box.appendChild(frame);
    frame.addEventListener("load", function () { status.textContent = ""; syncTheme(frame); fitFrame(frame); });
    fetch(url).then(function (r) { if (!r.ok) throw new Error(r.status); return r.text(); })
      .then(function (html) { frame.srcdoc = html; })
      .catch(function () { status.textContent = "Showing the report from its own file."; frame.src = url; });
  }
  new MutationObserver(function () {
    document.querySelectorAll(".report iframe").forEach(syncTheme);
  }).observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });

  // ---- Tabs, routed on the hash ----
  var TABS = ["summary", "mark", "alloc", "full-speed", "idle", "full-load"];
  function show(name) {
    if (TABS.indexOf(name) < 0) name = "summary";
    TABS.forEach(function (t) {
      var p = document.getElementById("panel-" + t), b = document.getElementById("tab-" + t);
      var on = t === name;
      p.hidden = !on; b.setAttribute("aria-selected", String(on)); b.tabIndex = on ? 0 : -1;
      if (on && p.hasAttribute("data-report")) loadReport(p);
    });
  }
  TABS.forEach(function (t, i) {
    var b = document.getElementById("tab-" + t);
    b.addEventListener("click", function () {
      if (location.hash !== "#" + t) location.hash = t; else show(t);
      var bar = document.querySelector(".tabbar");
      if (bar.getBoundingClientRect().top < 0 || window.scrollY > bar.offsetTop) window.scrollTo({ top: bar.offsetTop });
    });
    b.addEventListener("keydown", function (e) {
      var d = e.key === "ArrowRight" ? 1 : e.key === "ArrowLeft" ? -1 : 0; if (!d) return;
      var n = TABS[(i + d + TABS.length) % TABS.length]; document.getElementById("tab-" + n).focus(); location.hash = n;
    });
  });
  window.addEventListener("hashchange", function () { show(location.hash.slice(1)); });
  show(location.hash.slice(1));
