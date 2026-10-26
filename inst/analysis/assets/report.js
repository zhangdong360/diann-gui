/* =========================================================================
   report.js —— 分析报告模板交互脚本 (inst/analysis/assets/)
   重建自 mass_analysis 报告模板 (template_2grp/assets 缺失)。
   职责: TOC 生成 / 页内 tab 切换 / 图片点击放大 / 返回顶部 / 元数据与摘要填充。
   纯原生 JS, 无外部依赖; 报告可双击离线打开 (file://)。
   ========================================================================= */
(function () {
  "use strict";

  var doc = document;

  /* ---- 1. 元数据填充: REPORT_METADATA -> #meta-* ---- */
  function fillMetadata() {
    if (typeof REPORT_METADATA === "undefined" || !REPORT_METADATA) return;
    var map = {
      "report-date": REPORT_METADATA.report_date,
      "responsible-person": REPORT_METADATA.responsible_person,
      "responsible-email": REPORT_METADATA.responsible_email,
      "report-code": REPORT_METADATA.report_code
    };
    Object.keys(map).forEach(function (k) {
      var el = doc.getElementById("meta-" + k);
      if (el && map[k] != null && map[k] !== "") el.textContent = map[k];
    });
  }

  /* ---- 2. TOC: 由 h2.section / h3.subsection 生成 ---- */
  function buildToc() {
    var toc = doc.getElementById("toc");
    if (!toc) return;
    var heads = doc.querySelectorAll("main h2.section, main h3.subsection");
    if (!heads.length) return;
    var frag = doc.createDocumentFragment();
    var title = doc.createElement("div");
    title.className = "toc-title";
    title.textContent = "目录";
    frag.appendChild(title);
    Array.prototype.forEach.call(heads, function (h) {
      if (!h.id) return;
      var a = doc.createElement("a");
      a.href = "#" + h.id;
      a.textContent = h.textContent;
      a.className = h.tagName === "H2" ? "toc-h2" : "toc-h3";
      a.setAttribute("data-target", h.id);
      frag.appendChild(a);
    });
    toc.appendChild(frag);
  }

  /* ---- 3. TOC 滚动高亮 ---- */
  function watchToc() {
    var links = Array.prototype.slice.call(doc.querySelectorAll("#toc a[data-target]"));
    if (!links.length || !("IntersectionObserver" in window)) return;
    var visible = {};
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        visible[en.target.id] = en.isIntersecting ? en.intersectionRatio : 0;
      });
      var best = null, bestRatio = 0;
      links.forEach(function (a) {
        var r = visible[a.getAttribute("data-target")] || 0;
        if (r > bestRatio) { bestRatio = r; best = a; }
      });
      links.forEach(function (a) { a.classList.toggle("active", a === best); });
    }, { rootMargin: "-72px 0px -55% 0px", threshold: [0, 0.1, 0.5] });
    links.forEach(function (a) {
      var t = doc.getElementById(a.getAttribute("data-target"));
      if (t) io.observe(t);
    });
  }

  /* ---- 4. 页内 tab 切换 (.tab-btn[data-tab] -> .tab-pane#id) ---- */
  function bindTabs() {
    doc.addEventListener("click", function (ev) {
      var btn = ev.target.closest ? ev.target.closest(".tab-btn") : null;
      if (!btn) return;
      var scope = btn.closest(".tabs");
      if (!scope) return;
      var id = btn.getAttribute("data-tab");
      Array.prototype.forEach.call(scope.querySelectorAll(".tab-btn"), function (b) {
        b.classList.toggle("active", b === btn);
      });
      Array.prototype.forEach.call(scope.querySelectorAll(".tab-pane"), function (p) {
        p.classList.toggle("active", p.id === id);
      });
    });
  }

  /* ---- 5. 图片点击放大 (预览 = 报告 = 放大视图同一条 SVG) ---- */
  function bindZoom() {
    doc.addEventListener("click", function (ev) {
      var img = ev.target.closest ? ev.target.closest("img.zoomable") : null;
      if (!img) return;
      var on = img.classList.toggle("zoomed");
      doc.body.classList.toggle("img-zoomed", on);
    });
    doc.addEventListener("keydown", function (ev) {
      if (ev.key !== "Escape") return;
      var cur = doc.querySelector("img.zoomable.zoomed");
      if (cur) { cur.classList.remove("zoomed"); doc.body.classList.remove("img-zoomed"); }
    });
  }

  /* ---- 6. 返回顶部 ---- */
  function bindBackToTop() {
    var btn = doc.getElementById("backToTop");
    if (!btn) return;
    window.addEventListener("scroll", function () {
      btn.classList.toggle("show", window.scrollY > 400);
    }, { passive: true });
    btn.addEventListener("click", function () {
      window.scrollTo({ top: 0, behavior: "smooth" });
    });
  }

  /* ---- 7. 摘要数字占位: <span data-sum="key"> <- REPORT_SUMMARY[key] ---- */
  function fillSummary() {
    if (typeof REPORT_SUMMARY === "undefined" || !REPORT_SUMMARY) return;
    Array.prototype.forEach.call(doc.querySelectorAll("[data-sum]"), function (el) {
      var v = REPORT_SUMMARY[el.getAttribute("data-sum")];
      if (v != null && v !== "") el.textContent = v;
    });
  }

  doc.addEventListener("DOMContentLoaded", function () {
    fillMetadata();
    buildToc();
    watchToc();
    bindTabs();
    bindZoom();
    bindBackToTop();
    fillSummary();
  });
})();
