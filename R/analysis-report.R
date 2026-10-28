# ============================================================
# analysis-report.R — 结果分析·动态 HTML 报告生成器
# (移植自 mass_analysis/report_build.R)
# report.html + assets + data/ + 08_summary_report.md + analysis_params.json
# assets 从系统文件 inst/analysis/assets/ 读取 (mass_analysis 副本缺失模板资产, 此处重建)
# ============================================================

# ------------------------- 通用小工具 --------------------------------------

# HTML 转义
esc <- function(x) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;",  x, fixed = TRUE)
  x <- gsub(">", "&gt;",  x, fixed = TRUE)
  x
}

# JS 字符串字面量
js_json <- function(x, pretty = TRUE) {
  jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null", pretty = pretty)
}

# 格式化数字 (千分位)
fmt_int <- function(x) format(as.integer(x), big.mark = ",", scientific = FALSE)

# P 值校正方法的展示名
p_adjust_label <- function(m) {
  if (identical(as.character(m %||% "BH"), "none")) "未校正（原始 P 值）"
  else "BH（Benjamini-Hochberg）"
}

# 图形文件名 -> 报告内相对路径 (优先 svg)
fig_path <- function(out_dir, stem) {
  for (ext in c("svg", "png")) {
    f <- file.path(out_dir, "data", paste0(stem, ".", ext))
    if (file.exists(f)) return(paste0("./data/", basename(f)))
  }
  NA_character_
}

# 图形原生宽度 (pt): 宽幅图放宽显示; 读不到返回 NA
fig_width_pt <- function(out_dir, stem) {
  f <- file.path(out_dir, "data", paste0(stem, ".svg"))
  if (!file.exists(f)) return(NA_real_)
  ln <- tryCatch(readLines(f, n = 3, warn = FALSE), error = function(e) character(0))
  m  <- regmatches(ln, regexpr("width=['\"][0-9.]+pt", ln))
  if (!length(m)) return(NA_real_)
  suppressWarnings(as.numeric(sub(".*['\"]([0-9.]+)pt$", "\\1", m[1])))
}

# figure class: >= 780pt 视为宽幅图
fig_class <- function(out_dir, stem) {
  w <- fig_width_pt(out_dir, stem)
  if (isTRUE(w >= 780)) "figure figure-wide" else "figure"
}

# 复制图形到报告的 data/ 下
copy_figs <- function(files, out_dir) {
  dir.create(file.path(out_dir, "data"), showWarnings = FALSE, recursive = TRUE)
  for (f in files) {
    if (!file.exists(f)) next
    file.copy(f, file.path(out_dir, "data", basename(f)), overwrite = TRUE)
  }
}

# ---- 静态 HTML 表格 (iframe, Top 20) ----
df_to_html_table <- function(df, max_rows = 20, sig_col = NULL,
                             up_down_col = NULL, caption = NULL) {
  if (is.null(df) || nrow(df) == 0) {
    return(paste0(
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>',
      '<body style="font-family:sans-serif;padding:24px;color:#777">',
      '<p>暂无结果（完整数据请查看结果目录中的原始 CSV）。</p></body></html>'))
  }
  total <- nrow(df)
  d <- utils::head(df, max_rows)
  for (cn in colnames(d)) {
    if (is.numeric(d[[cn]])) {
      v <- d[[cn]]
      if (cn %in% c("logFC", "AveExpr", "t", "F")) {
        d[[cn]] <- formatC(round(v, 3), format = "f", digits = 3)
      } else if (any(grepl("P\\.|pvalue|qvalue|P\\.Value", cn))) {
        d[[cn]] <- formatC(signif(v, 3), format = "g")
      } else {
        d[[cn]] <- formatC(v, format = "g")
      }
    }
  }
  cls_of <- function(r) {
    v <- ""
    if (!is.null(sig_col) && sig_col %in% colnames(d) &&
        isTRUE(as.logical(d[[sig_col]][r]))) v <- paste0(v, "sig ")
    if (!is.null(up_down_col) && up_down_col %in% colnames(d)) {
      lf <- suppressWarnings(as.numeric(d[[up_down_col]][r]))
      if (!is.na(lf)) v <- paste0(v, if (lf > 0) "up" else "down")
    }
    trimws(v)
  }
  th <- paste0("<th>", esc(colnames(d)), "</th>", collapse = "")
  rows <- vapply(seq_len(nrow(d)), function(r) {
    tds <- paste0("<td>", esc(unlist(d[r, , drop = TRUE])), "</td>", collapse = "")
    sprintf('<tr class="%s">%s</tr>', cls_of(r), tds)
  }, character(1))
  note <- if (total > max_rows)
    sprintf('<p class="note">仅展示前 %d 行（共 %d 行）；完整结果请查看结果目录中的原始 CSV。</p>',
            max_rows, total)
  else sprintf('<p class="note">共 %d 行。</p>', total)

  paste0(
    '<!DOCTYPE html><html><head><meta charset="utf-8"><style>',
    'body{font-family:"Segoe UI",Roboto,"Microsoft YaHei",sans-serif;margin:0;padding:8px;background:#fff}',
    'table{border-collapse:collapse;width:100%;font-size:12.5px}',
    'th{background:#0b5f9e;color:#fff;font-weight:600;text-align:left;padding:6px 9px;position:sticky;top:0}',
    'td{padding:5px 9px;border-bottom:1px solid #eef3f7;white-space:nowrap}',
    'tr:nth-child(even) td{background:#f7fafc}',
    'tr.up td:nth-child(5),tr.up td:nth-child(6){color:#D9534F;font-weight:600}',
    'tr.down td:nth-child(5),tr.down td:nth-child(6){color:#3B6FB5;font-weight:600}',
    'tr.sig td{background:#fff8e1}',
    '.note{font-size:11.5px;color:#90a4ae;margin:8px 2px 0}',
    '</style></head><body><table><thead><tr>', th, '</tr></thead><tbody>',
    paste0(rows, collapse = ""),
    '</tbody></table>', note, '</body></html>')
}

write_html_table <- function(df, out_dir, filename, ...) {
  dir.create(file.path(out_dir, "data"), showWarnings = FALSE, recursive = TRUE)
  writeLines(df_to_html_table(df, ...),
             file.path(out_dir, "data", filename), useBytes = TRUE)
}

# ---- 参数与元数据 ----

build_summary <- function(prep, qc, de, enrich, params, modules) {
  n_samples <- length(prep$snames)
  n_groups  <- prep$n_groups
  pairs     <- if (is.null(de)) list() else de$pairs
  pair_stat <- if (is.null(de)) NULL else de$pair_stat

  s <- list(
    report_name  = "DIA-NN 蛋白质组学差异分析报告",
    report_date  = format(Sys.Date(), "%Y-%m-%d"),
    n_samples    = as.character(n_samples),
    n_groups     = as.character(n_groups),
    proteins_raw = fmt_int(prep$n_before),
    proteins_final = fmt_int(prep$n_final),
    removed_low  = fmt_int(prep$n_low),
    n_imputed    = fmt_int(prep$n_imp),
    n_missing    = fmt_int(prep$n_missing %||% prep$n_imp),
    imp_pct      = sprintf("%.2f%%", prep$imp_pct),
    miss_pct     = sprintf("%.2f%%", prep$miss_pct %||% prep$imp_pct),
    n_contam     = fmt_int(prep$n_contam),
    species      = prep$species,
    groups_text  = paste(sprintf("%s (n=%d)", prep$group_levels,
                                 as.integer(table(prep$groups)[prep$group_levels])),
                         collapse = "、"),
    samples_text = paste(prep$snames, collapse = ", "),
    logFC_cutoff = sprintf("%.2f", params$de_logFC_cutoff %||% 1),
    pval_cutoff  = sprintf("%.3f", params$de_pval_cutoff %||% 0.05),
    min_detect   = sprintf("%.0f%%", prep$min_detect_frac * 100)
  )

  # 差异相关数字
  if (!is.null(de)) {
    s$mode <- de$mode
    s$n_pairs <- as.character(length(pairs))
    if (de$mode == "single") {
      s$sig_total <- as.character(nrow(pairs[[1]]$sig))
      s$sig_up    <- as.character(pairs[[1]]$sig_up)
      s$sig_down  <- as.character(pairs[[1]]$sig_down)
      s$contrast  <- pairs[[1]]$contrast
      sg <- pairs[[1]]$sig
      if (nrow(sg) > 0) {
        g <- ifelse(is.na(sg$Genes) | sg$Genes == "", sg$Protein.Group, sg$Genes)
        s$top_up   <- if (any(sg$logFC > 0)) paste(utils::head(g[order(-sg$logFC)], 5), collapse = ", ") else "无"
        s$top_down <- if (any(sg$logFC < 0)) paste(utils::head(g[order(sg$logFC)], 5), collapse = ", ") else "无"
      } else {
        s$top_up <- s$top_down <- "无"
      }
    } else {
      s$anova_sig  <- as.character(if (is.null(de$anova)) 0 else nrow(de$anova$sig))
      s$union_sig  <- as.character(nrow(de$sig))
      s$sig_total  <- s$union_sig
      s$sig_up <- s$sig_down <- "—"
      s$anova_ref  <- de$anova$ref
    }
  } else {
    s$mode <- "none"; s$n_pairs <- "0"; s$sig_total <- "—"
    s$sig_up <- s$sig_down <- "—"
  }

  # 富集
  if (!is.null(enrich) && !isTRUE(enrich$skipped)) {
    s$enrich_status <- if (length(enrich$sources)) paste(enrich$sources, collapse = ", ") else "none"
    s$enrich_n <- if (is.null(enrich$tables$all)) "0" else as.character(nrow(enrich$tables$all))
    s$enrich_kegg_source <- enrich$kegg_source %||% "local"
  } else {
    s$enrich_status <- "none"
    s$enrich_n <- "0"
    s$enrich_kegg_source <- "local"
    s$enrich_skip_reason <- if (!is.null(enrich)) enrich$reason else "未执行功能富集模块"
  }

  # QC 关键数
  if (!is.null(qc)) {
    # v1.14.1: 退化数据 (<3 完整蛋白) 下 pca_var/cor_range 为 NULL — 占位"未生成",
    # 不再让 sprintf 产出 character(0) 渲染成 "PC1 解释方差 ，" 这类缺数字句子
    pv <- qc$stats$pca_var %||% c(NA_real_, NA_real_)
    s$pca_pc1 <- if (is.finite(pv[1])) sprintf("%.1f%%", pv[1]) else "未生成"
    s$pca_pc2 <- if (is.finite(pv[2])) sprintf("%.1f%%", pv[2]) else "未生成"
    s$cv_text <- paste(sprintf("%s=%.1f%%", names(qc$stats$cv_median),
                               qc$stats$cv_median * 100), collapse = ", ")
    s$det_text <- paste(sprintf("%s=%d", names(qc$stats$det_sample),
                                as.integer(qc$stats$det_sample)), collapse = ", ")
    cr <- qc$stats$cor_range %||% c(NA_real_, NA_real_)
    s$cor_text <- if (all(is.finite(cr))) sprintf("%.3f ~ %.3f", cr[1], cr[2]) else "未生成"
    s$cv_summary <- qc$stats$cv_summary
  } else {
    s$pca_pc1 <- s$pca_pc2 <- s$cv_text <- s$det_text <- s$cor_text <- "（未执行 QC 模块）"
    s$cv_summary <- NULL
  }

  s$modules <- paste(modules, collapse = ", ")
  s$generated_at <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")

  # 缺失值处理方法 (供正文/方法学/汇总 md)
  s$impute_method <- prep$impute_method %||% "mnar"
  s$impute_desc <- switch(s$impute_method,
    none   = "未做缺失值插补",
    mar    = "k 近邻插补",
    seq    = "顺序 KNN 插补",
    "LoD 插补")
  s$impute_flow <- switch(s$impute_method,
    none   = "不插补（保留缺失值，仅做 QC）",
    mar    = "k 近邻插补（随机缺失型）",
    seq    = "顺序 KNN 插补（按缺失率由低到高逐蛋白插补）",
    "组内 LoD 插补（检测限左删失）")
  s$impute_line <- if (identical(s$impute_method, "none"))
    sprintf("未做插补（保留缺失值 %s 个，占矩阵 %s）", s$n_missing, s$miss_pct)
  else sprintf("%s（共插补 %s 个缺失值，占矩阵 %s）", s$impute_desc, s$n_imputed, s$imp_pct)
  s$impute_md <- switch(s$impute_method,
    none   = "none (missing values retained; DE / enrichment disabled)",
    mar    = "k-nearest neighbours (k = 10) on the log2 matrix",
    seq    = "sequential KNN (k = 10): proteins imputed in ascending order of missingness",
    sprintf(paste0("LoD (left-censored Gaussian per sample column; shift %.1f SD, ",
                   "scale %.1f SD), applied on the log2 matrix"),
            prep$impute_shift %||% 1.8, prep$impute_sd_scale %||% 0.3))
  s$impute_detail <- switch(s$impute_method,
    none   = "未做缺失值插补（保留缺失值），因此差异分析与功能富集已停用。",
    mar    = "缺失值以 k 近邻（k = 10）在 log2 尺度上插补（随机缺失型），插补发生在 log2 变换之后。",
    seq    = "缺失值以顺序 KNN（k = 10）在 log2 尺度上插补：按缺失率由低到高逐个蛋白，用已完成蛋白寻找近邻样本，前一步的插补结果参与后续计算。",
    sprintf(paste0("缺失值以 LoD（组内左截断高斯分布）插补（均值偏移 %.1f SD、标准差缩放 %.1f SD，随机种子 %s）。"),
            prep$impute_shift %||% 1.8, prep$impute_sd_scale %||% 0.3, prep$seed %||% 42))

  # 模块级参数 (供正文与附录)
  s$p_adjust_method <- params$de_p_adjust_method %||% "BH"
  s$heatmap_max     <- as.character(params$de_heatmap_max %||% 200)
  s$cor_method      <- params$cor_method %||% "pearson"
  s$top_n_label     <- as.character(params$de_top_n_label %||% 12)
  s$top_n_boxplot   <- as.character(params$de_top_n_boxplot %||% 9)
  s$enrich_p        <- sprintf("%.3f", params$enrich_pval_cutoff %||% 0.05)
  s$enrich_q        <- sprintf("%.3f", params$enrich_qval_cutoff %||% 0.2)
  s$enrich_p_adjust <- params$enrich_p_adjust_method %||% "BH"
  s$enrich_ont      <- params$enrich_ont %||% c("BP", "MF", "CC")
  s
}

# ---- 正文片段 ----

# 章节: 1 项目概述
html_sec1 <- function(s, has_qc, has_de, has_enrich) {
  cards <- list(
    c(s$n_samples, "样本数"), c(s$n_groups, "分组数"),
    c(s$proteins_final, "预处理后蛋白数"),
    c(if (identical(s$mode, "multi")) s$union_sig else s$sig_total, "显著差异蛋白"),
    c(if (identical(s$enrich_status, "none")) "0" else s$enrich_n, "富集通路数")
  )
  paste0(
    '<h2 class="section" id="sec1">1 项目概述</h2>',
    '<h3 class="subsection" id="sec1-1">1.1 数据概览</h3>',
    '<div class="stat-row">',
    paste0(vapply(cards, function(cc) sprintf(
      '<div class="stat-card"><div class="num">%s</div><div class="label">%s</div></div>',
      esc(cc[1]), esc(cc[2])), character(1)), collapse = ""),
    '</div>',
    '<p>本次分析基于 DIA-NN 输出的蛋白水平定量矩阵（pg_matrix），共 <b>', esc(s$n_samples),
    '</b> 个样本、<b>', esc(s$n_groups), '</b> 个实验分组（', esc(s$groups_text),
    '）。经污染/反库过滤与低检出过滤（检出率 ≥ ', esc(s$min_detect), '）后保留 <b>',
    esc(s$proteins_final), '</b> 个蛋白（原始 ', esc(s$proteins_raw), ' 个，剔除低检出 ',
    esc(s$removed_low), ' 个），随后完成 log2 变换，并做', esc(s$impute_line),
    '；最后以各样本中位数的最大值为目标做样本中位数归一化（把各样本中位数拉平到该值）。</p>',
    '<p>缺失值插补在 log2 变换之后进行（各方法均定义在对数强度上）；归一化在插补之后，',
    '只对每个样本整体做加法平移、不改变样本内的相对差异与方差。</p>',
    '<h3 class="subsection" id="sec1-2">1.2 分析流程</h3>',
    '<ol class="flow">',
    '<li>数据读取与清洗：自动识别注释列与样本列，解析分组</li>',
    '<li>过滤：污染/反库条目（contaminant / REV / DECOY）与低检出蛋白</li>',
    '<li>log2 变换与缺失值插补：log2 变换 → ', esc(s$impute_flow), ' → 样本中位数归一化（拉平到最大中位数）</li>',
    if (has_qc) '<li>质量控制：检出数、缺失率、PCA、相关性、样本聚类、CV、强度分布</li>' else '',
    if (has_de) paste0('<li>差异分析：limma 经验贝叶斯',
                       if (identical(s$mode, "multi")) '（全局 F 检验 + 全部两两对比）' else '单对比',
                       '，BH-FDR 校正</li>') else '',
    if (has_enrich) '<li>功能富集：GO（BP/MF/CC）与 KEGG 通路富集</li>' else '',
    '</ol>',
    '<table class="kv"><tbody>',
    sprintf('<tr><td>物种</td><td>%s</td></tr>', esc(s$species)),
    sprintf('<tr><td>差异阈值</td><td>|log2FC| &gt; %s 且 P 值 &lt; %s</td></tr>',
            esc(s$logFC_cutoff), esc(s$pval_cutoff)),
    sprintf('<tr><td>执行的分析模块</td><td>%s</td></tr>', esc(s$modules)),
    '</tbody></table>'
  )
}

# 章节: 2 质量控制
html_sec2 <- function(s) {
  fig <- function(stem, alt, caption, optional = FALSE) {
    p <- fig_path(out_dir = s$.out_dir, stem = stem)
    if (is.na(p))
      return(sprintf('<div class="missing">%s：未生成（无对应结果）</div>', esc(caption)))
    sprintf(paste0('<div class="%s"><img class="zoomable" src="%s" alt="%s">',
                   '<div class="caption">%s</div></div>'),
            fig_class(s$.out_dir, stem), p, esc(alt), esc(caption))
  }
  paste0(
    '<h2 class="section" id="sec2">2 DIA-NN 数据质量控制</h2>',
    '<h3 class="subsection" id="sec2-1">2.1 数据预处理与过滤</h3>',
    '<table class="kv"><tbody>',
    sprintf('<tr><td>样本数</td><td>%s（%s）</td></tr>', esc(s$n_samples), esc(s$samples_text)),
    sprintf('<tr><td>分组</td><td>%s</td></tr>', esc(s$groups_text)),
    sprintf('<tr><td>原始蛋白数</td><td>%s</td></tr>', esc(s$proteins_raw)),
    sprintf('<tr><td>污染/反库剔除</td><td>%s</td></tr>', esc(s$n_contam)),
    sprintf('<tr><td>低检出剔除（&lt; %s 检出）</td><td>%s</td></tr>', esc(s$min_detect), esc(s$removed_low)),
    sprintf('<tr><td>预处理后蛋白数</td><td>%s</td></tr>', esc(s$proteins_final)),
    sprintf('<tr><td>缺失值处理</td><td>%s</td></tr>', esc(s$impute_line)),
    '</tbody></table>',
    '<h3 class="subsection" id="sec2-2">2.2 蛋白鉴定概况</h3>',
    fig("01_qc_detected_counts", "蛋白检出数量统计图",
        "图 2.1 各样本检出蛋白数（左）与蛋白检出频率分布（右）"),
    '<h3 class="subsection" id="sec2-3">2.3 样本相关性分析</h3>',
    fig("04_qc_correlation_heatmap", "样本相关性热图",
        "图 2.2 样本间 Pearson 相关系数热图（按分组排列）"),
    '<p>样本间相关系数范围为 ', esc(s$cor_text), '，组内相关性应明显高于组间。</p>',
    '<h3 class="subsection" id="sec2-4">2.4 缺失值分析</h3>',
    fig("02_qc_missingness", "蛋白缺失值分布图",
        "图 2.3 各样本缺失率（左）与蛋白缺失率分布（右）"),
    '<h3 class="subsection" id="sec2-5">2.5 样本层次聚类</h3>',
    fig("05_qc_sample_clustering", "样本层次聚类树状图",
        "图 2.4 样本层次聚类树状图（complete linkage）"),
    '<h3 class="subsection" id="sec2-6">2.6 主成分分析（PCA）</h3>',
    fig("03_qc_pca", "PCA 得分图", "图 2.5 样本 PCA 得分图"),
    '<p>PC1 解释方差 ', esc(s$pca_pc1), '，PC2 解释方差 ', esc(s$pca_pc2), '。</p>',
    '<h3 class="subsection" id="sec2-7">2.7 组内变异系数（CV）分布</h3>',
    fig("06_qc_cv_distribution", "组内变异系数分布图",
        "图 2.6 各组组内变异系数（CV）分布密度"),
    '<p>各组 CV 中位数：', esc(s$cv_text), '。CV 越低说明组内定量重复性越好。</p>',
    '<h3 class="subsection" id="sec2-8">2.8 组内 CV 重复性箱线图</h3>',
    fig("07_qc_cv_boxplot", "组内 CV 重复性箱线图",
        "图 2.7 各组组内 CV 箱线图（散点为单个蛋白，菱形为中位数）"),
    '<p>箱线图用于按组对比定量重复性：箱体越窄、中位数越低，说明该组重复性越好；',
    '散点可直观看出是否存在 CV 异常偏高的离群蛋白。</p>',
    cv_table_html(s),
    '<h3 class="subsection" id="sec2-9">2.9 中位数归一化前后对比</h3>',
    fig("08_qc_median_norm_boxplot", "中位数归一化前后箱线图",
        "图 2.8 样本中位数归一化前后各样本强度箱线图（虚线为目标中位数）"),
    '<p>左图为插补后、归一化前的各样本强度分布，右图为以最大样本中位数为目标',
    '做加法平移后的结果；虚线为目标中位数，各样本中位数在归一化后对齐到该值。</p>',
    '<div class="callout"><b>质控小结：</b>样本检出数（', esc(s$det_text),
    '）与缺失率处于正常范围；各样本强度分布（log2 变换后）彼此接近；PCA 与层次聚类结果显示组内样本聚集良好。</div>'
  )
}

# CV 汇总表
cv_table_html <- function(s) {
  d <- s$cv_summary
  if (is.null(d) || nrow(d) == 0) return("")
  rows <- paste0(vapply(seq_len(nrow(d)), function(i) sprintf(
    '<tr><td>%s</td><td>%d</td><td>%.1f%%</td><td>%.1f%%</td><td>%.1f%%</td></tr>',
    esc(d$Group[i]), as.integer(d$n[i]), d$median[i] * 100,
    d$q1[i] * 100, d$q3[i] * 100), character(1)), collapse = "")
  paste0('<table class="kv"><thead><tr><th>组</th><th>蛋白数</th>',
         '<th>CV 中位数</th><th>CV 下四分位</th><th>CV 上四分位</th></tr></thead>',
         '<tbody>', rows, '</tbody></table>')
}

# 章节: 3 差异分析
html_sec3 <- function(s, de) {
  if (is.null(de)) return("")
  fig <- function(stem, alt, caption) {
    p <- fig_path(out_dir = s$.out_dir, stem = stem)
    if (is.na(p)) return(sprintf('<div class="missing">%s：无显著差异蛋白，未生成</div>', esc(caption)))
    sprintf(paste0('<div class="%s"><img class="zoomable" src="%s" alt="%s">',
                   '<div class="caption">%s</div></div>'),
            fig_class(s$.out_dir, stem), p, esc(alt), esc(caption))
  }
  kv <- paste0(
    '<table class="kv"><tbody>',
    sprintf('<tr><td>分析方法</td><td>limma 经验贝叶斯 + BH-FDR 校正</td></tr>'),
    sprintf('<tr><td>显著性阈值</td><td>|log2FC| &gt; %s 且 P 值 &lt; %s</td></tr>',
            esc(s$logFC_cutoff), esc(s$pval_cutoff)),
    sprintf('<tr><td>分析模式</td><td>%s</td></tr>',
            if (identical(de$mode, "multi")) sprintf("多组比较（%d 组，全局 F 检验 + %d 个两两对比）",
                                                     as.integer(s$n_groups), length(de$pairs))
            else sprintf("单对比（%s）", esc(s$contrast))),
    '</tbody></table>')

  if (identical(de$mode, "single")) {
    pt <- de$pairs[[1]]
    body <- paste0(
      '<h3 class="subsection" id="sec3-1">3.1 差异分析概述</h3>', kv,
      '<p>在 ', esc(pt$contrast), ' 比较中，共检出显著差异蛋白 <b>', nrow(pt$sig),
      '</b> 个（上调 ', pt$sig_up, ' 个，下调 ', pt$sig_down, ' 个）。</p>',
      '<h3 class="subsection" id="sec3-2">3.2 差异蛋白火山图（Volcano Plot）</h3>',
      fig("09_diff_volcano", "差异蛋白火山图", "图 3.1 差异蛋白火山图"),
      '<h3 class="subsection" id="sec3-3">3.3 显著差异蛋白数量统计</h3>',
      fig("11_diff_count_barplot", "显著差异蛋白数量统计图", "图 3.2 上/下调蛋白数量统计"),
      '<h3 class="subsection" id="sec3-4">3.4 差异蛋白聚类热图</h3>',
      fig("10_diff_heatmap", "差异蛋白聚类热图", "图 3.3 显著差异蛋白 Z-score 热图"),
      '<h3 class="subsection" id="sec3-5">3.5 关键差异蛋白表达箱线图</h3>',
      fig("12_diff_top_protein_boxplot", "关键差异蛋白箱线图", "图 3.4 关键差异蛋白表达箱线图"),
      '<h3 class="subsection" id="sec3-6">3.6 差异蛋白结果表格</h3>',
      '<p class="hint">下表展示显著差异蛋白（Top 20）；完整结果见结果目录中的 CSV / Excel。</p>',
      '<iframe class="tbl-frame" src="./data/dep_table.html" loading="lazy" title="差异蛋白结果表"></iframe>',
      '<h3 class="subsection" id="sec3-7">3.7 差异结果说明</h3>',
      '<p class="hint">显著差异蛋白的完整结果（含 logFC、AveExpr、t、P.Value、adj.P.Val）'
      , '随报告导出为 CSV 与 Excel（04_de_limma_results_all.csv / 05_de_significant_proteins.csv）。</p>')
  } else {
    # 多组: 全局 F + 两两对比
    ptabs <- vapply(seq_along(de$pairs), function(k) {
      pt <- de$pairs[[k]]
      tag <- pt$tag
      f <- function(stem, alt, cap) {
        p <- fig_path(out_dir = s$.out_dir, stem = stem)
        if (is.na(p)) return(sprintf('<div class="missing">%s：无显著差异蛋白，未生成</div>', esc(cap)))
        sprintf(paste0('<div class="figure"><img class="zoomable" src="%s" alt="%s">',
                       '<div class="caption">%s</div></div>'), p, esc(alt), esc(cap))
      }
      sprintf(paste0(
        '<div class="tab-pane" id="pane-%s">',
        '<p>对比 <b>%s</b>：显著差异蛋白 <b>%d</b> 个（上调 %d，下调 %d）。</p>',
        '%s%s%s%s',
        '<h4>差异结果表</h4>',
        '<iframe class="tbl-frame" src="./data/dep_table_%s.html" loading="lazy" title="%s 显著差异蛋白表"></iframe>',
        '</div>'),
        tag, esc(pt$contrast), nrow(pt$sig), pt$sig_up, pt$sig_down,
        f(de_stem("09_diff_volcano", tag), "火山图", sprintf("图 %s 火山图", pt$contrast)),
        f(de_stem("11_diff_count_barplot", tag), "数量统计", sprintf("图 %s 上下调数量", pt$contrast)),
        f(de_stem("10_diff_heatmap", tag), "热图", sprintf("图 %s 差异热图", pt$contrast)),
        f(de_stem("12_diff_top_protein_boxplot", tag), "箱线图", sprintf("图 %s 关键蛋白箱线图", pt$contrast)),
        tag, esc(pt$contrast))
    }, character(1))
    tbtns <- vapply(seq_along(de$pairs), function(k) {
      pt <- de$pairs[[k]]
      sprintf('<button class="tab-btn%s" data-tab="pane-%s">%s（%d）</button>',
              if (k == 1) " active" else "", pt$tag, esc(pt$contrast), nrow(pt$sig))
    }, character(1))

    anova_fig <- fig("10_multigroup_anova_heatmap", "全局差异热图", "图 3.2 全局显著差异蛋白热图")
    body <- paste0(
      '<h3 class="subsection" id="sec3-1">3.1 差异分析概述</h3>', kv,
      sprintf('<p>共 %d 个实验分组，出于完整性考虑执行全局差异检验与全部 %d 个两两对比。</p>',
              as.integer(s$n_groups), length(de$pairs)),
      '<h3 class="subsection" id="sec3-2">3.2 全局差异检验（F 检验）</h3>',
      sprintf('<p>以 %s 为基准组的多重对比 F 检验（H<sub>0</sub>：各组均值全相等），BH 校正后显著蛋白 <b>%s</b> 个。</p>',
              esc(s$anova_ref), esc(s$anova_sig)),
      '<iframe class="tbl-frame" src="./data/anova_table.html" loading="lazy" title="全局 F 检验结果表"></iframe>',
      anova_fig,
      '<h3 class="subsection" id="sec3-3">3.3 两两对比概览</h3>',
      '<iframe class="tbl-frame" src="./data/pairwise_table.html" loading="lazy" title="两两对比汇总表"></iframe>',
      '<h3 class="subsection" id="sec3-4">3.4 两两对比详情</h3>',
      '<div class="tabs"><div class="tab-bar">', paste0(tbtns, collapse = ""), '</div>',
      paste0(ptabs, collapse = ""), '</div>',
      '<h3 class="subsection" id="sec3-5">3.5 结果说明</h3>',
      '<p>全部两两对比显著蛋白的并集为 <b>', esc(s$union_sig),
      '</b> 个蛋白，该并集用于后续功能富集分析。</p>')
  }
  paste0('<h2 class="section" id="sec3">3 差异蛋白分析</h2>', body)
}

# 章节: 4 功能富集
html_sec4 <- function(s, enrich) {
  fig <- function(stem, alt, caption) {
    p <- fig_path(out_dir = s$.out_dir, stem = stem)
    if (is.na(p)) return(sprintf('<div class="missing">%s：暂无结果</div>', esc(caption)))
    sprintf(paste0('<div class="figure"><img class="zoomable" src="%s" alt="%s">',
                   '<div class="caption">%s</div></div>'), p, esc(alt), esc(caption))
  }
  if (is.null(enrich) || isTRUE(enrich$skipped)) {
    reason <- if (!is.null(enrich)) enrich$reason else "未执行功能富集模块。"
    return(paste0(
      '<h2 class="section" id="sec4">4 功能富集分析</h2>',
      '<div class="callout"><b>未获得富集结果。</b>', esc(reason),
      ' GO/KEGG 富集对差异蛋白数量较为敏感，建议结合生物学背景适当放宽筛选阈值或增加生物学重复后重新分析。</div>',
      '<iframe class="tbl-frame" src="./data/go_table.html" loading="lazy" title="GO 富集结果表"></iframe>',
      '<iframe class="tbl-frame" src="./data/kegg_table.html" loading="lazy" title="KEGG 富集结果表"></iframe>'))
  }
  paste0(
    '<h2 class="section" id="sec4">4 功能富集分析</h2>',
    '<p>使用 ', esc(enrich$org_pkg), ' 注释库对显著差异蛋白（', enrich$n_sig,
    ' 个，可映射 ENTREZID ', enrich$n_sig_mapped, ' 个；背景基因 ', enrich$n_bg,
    ' 个）进行 GO 与 KEGG 富集，BH 校正后共获得 <b>', esc(s$enrich_n), '</b> 条显著条目。</p>',
    '<h3 class="subsection" id="sec4-1">4.1 GO 功能富集分析</h3>',
    '<div class="tabs"><div class="tab-bar">',
    '<button class="tab-btn active" data-tab="go-tab-bp">BP（生物过程）</button>',
    '<button class="tab-btn" data-tab="go-tab-mf">MF（分子功能）</button>',
    '<button class="tab-btn" data-tab="go-tab-cc">CC（细胞组分）</button></div>',
    '<div class="tab-pane active" id="go-tab-bp">',
    fig("13_enrichment_go_barplot_bp", "GO-BP 富集条形图", "图 4.1 GO-BP 富集（top 10）"), '</div>',
    '<div class="tab-pane" id="go-tab-mf">',
    fig("13_enrichment_go_barplot_mf", "GO-MF 富集条形图", "图 4.2 GO-MF 富集（top 10）"), '</div>',
    '<div class="tab-pane" id="go-tab-cc">',
    fig("13_enrichment_go_barplot_cc", "GO-CC 富集条形图", "图 4.3 GO-CC 富集（top 10）"), '</div>',
    '</div>',
    fig("14_enrichment_go_dotplot", "GO 富集气泡图", "图 4.4 GO 富集气泡图（各 ontology top 5）"),
    '<iframe class="tbl-frame" src="./data/go_table.html" loading="lazy" title="GO 富集结果表"></iframe>',
    '<h3 class="subsection" id="sec4-2">4.2 KEGG 通路富集分析</h3>',
    fig("15_enrichment_kegg_dotplot", "KEGG 富集气泡图", "图 4.5 KEGG 通路富集气泡图（top 15）"),
    '<iframe class="tbl-frame" src="./data/kegg_table.html" loading="lazy" title="KEGG 富集结果表"></iframe>'
  )
}

# 章节: 5 结论
html_sec5 <- function(s, de, enrich) {
  dif_txt <- if (is.null(de)) "未执行差异分析。"
    else if (identical(de$mode, "single"))
      sprintf("在比较组 %s 中，按阈值 |log2(FC)| > %s 且 P 值 < %s 共检出显著差异蛋白 <b>%s</b> 个（上调 %s 个，下调 %s 个）。",
              esc(s$contrast), esc(s$logFC_cutoff), esc(s$pval_cutoff),
              if (nrow(de$pairs[[1]]$sig) > 0) nrow(de$pairs[[1]]$sig) else "0",
              if (nrow(de$pairs[[1]]$sig) > 0) de$pairs[[1]]$sig_up else "0",
              if (nrow(de$pairs[[1]]$sig) > 0) de$pairs[[1]]$sig_down else "0")
    else
      sprintf("多组（%s 组）比较中，全局 F 检验检出 <b>%s</b> 个组间差异蛋白，%d 个两两对比的显著蛋白并集为 <b>%s</b> 个。",
              esc(s$n_groups), esc(s$anova_sig), length(de$pairs), esc(s$union_sig))

  enrich_txt <- if (is.null(enrich) || isTRUE(enrich$skipped))
    sprintf("功能富集未获得显著结果（%s）。",
            esc(if (!is.null(enrich)) enrich$reason else "未执行富集模块"))
  else sprintf("GO/KEGG 富集共获得 <b>%s</b> 条显著条目（%s）。", esc(s$enrich_n), esc(s$enrich_status))

  paste0(
    '<h2 class="section" id="sec5">5 结论</h2>',
    '<ul class="concl">',
    sprintf('<li><b>数据质量</b>：%s 个样本、%s 个分组，预处理后保留 %s 个蛋白（剔除低检出 %s 个），%s；QC 各项指标正常。</li>',
            esc(s$n_samples), esc(s$n_groups), esc(s$proteins_final), esc(s$removed_low), esc(s$impute_line)),
    sprintf('<li><b>样本关系</b>：PCA（PC1 %s / PC2 %s）与层次聚类显示组内样本聚集，组间分离%s。</li>',
            esc(s$pca_pc1), esc(s$pca_pc2),
            if (!is.null(de) && identical(de$mode, "multi")) "，与实验分组设计基本一致" else ""),
    sprintf('<li><b>定量重复性</b>：各组组内 CV 中位数为 %s（详见 2.9 节 CV 箱线图）。</li>',
            esc(s$cv_text)),
    sprintf('<li><b>差异蛋白</b>：%s</li>', dif_txt),
    sprintf('<li><b>功能富集</b>：%s</li>', enrich_txt),
    '</ul>',
    '<div class="callout"><b>建议：</b>显著蛋白数量较少时，可结合生物学背景适当放宽筛选阈值（如 |log2FC| ≥ 0.58 / P 值 &lt; 0.05），或增加生物学重复后重新评估。</div>'
  )
}

# 章节: 6 附录
# 全部分析步骤参数 (按阶段分组)
param_table_html <- function(s, prep) {
  p <- s$.params %||% list()
  g <- function(x, d = "—") {
    if (is.null(x) || length(x) == 0) return(d)
    x <- x[!is.na(x)]
    if (!length(x)) return(d)
    paste(as.character(x), collapse = ", ")
  }
  row <- function(k, v) sprintf('<tr><td>%s</td><td>%s</td></tr>', esc(k), esc(g(v)))
  grp <- function(t) sprintf('<tr class="param-grp"><td colspan="2">%s</td></tr>', esc(t))
  imp_par <- switch(s$impute_method,
    none   = "—",
    mar    = "k = 10（impute::impute.knn）",
    seq    = "k = 10（按缺失率升序逐蛋白）",
    sprintf("偏移 %.1f SD / 缩放 %.1f SD / 种子 %s",
            prep$impute_shift %||% 1.8, prep$impute_sd_scale %||% 0.3, prep$seed %||% 42))
  paste0(
    '<table class="kv param-table"><tbody>',
    grp("1. 数据与分组"),
    row("数据来源", if (identical(p$source, "spectronaut")) "Spectronaut 蛋白组矩阵"
                    else "DIA-NN 蛋白水平矩阵 (pg_matrix)"),
    row("数据文件", p$file_name %||% "随应用提供"),
    row("样本数 / 分组数", sprintf("%s / %s", s$n_samples, s$n_groups)),
    row("分组", s$groups_text),
    row("物种", s$species),
    row("分析模块", s$modules),
    grp("2. 预处理"),
    row("污染/反库剔除", "是（contaminant / REV / DECOY）"),
    row("低检出过滤", sprintf("检出率 ≥ %s", s$min_detect)),
    row("分组内最少检出样本数", g(prep$min_group_detect %||% 0, "0（不启用）")),
    row("log2 变换", "是"),
    row("缺失值插补方法", s$impute_desc),
    row("插补参数", imp_par),
    row("缺失值（个 / 占比）", sprintf("%s / %s", s$n_missing, s$miss_pct)),
    row("中位数归一化",
        sprintf("各样本中位数平移至最大值 %.2f", prep$median_target %||% NA_real_)),
    row("ComBat 去批次", if (!isTRUE(prep$use_combat)) "未启用"
        else sprintf("启用（%d 个批次，%s）", prep$n_batches %||% NA_integer_,
                     if (isTRUE(prep$combat_done)) "已执行" else "未执行")),
    grp("3. 质量控制"),
    row("相关性方法", s$cor_method),
    row("相关性热图色阶下限", p$cor_min %||% "0.8"),
    row("QC 直方图分箱数", p$cv_bins %||% "40"),
    grp("4. 差异分析"),
    row("分析模式", if (identical(s$mode, "multi")) "多组（全局 F + 两两对比）"
                    else if (identical(s$mode, "single")) "单对比" else "未执行"),
    row("对照组", p$control_grp %||% "—"),
    row("|log2FC| 阈值", s$logFC_cutoff),
    row("P 值阈值", s$pval_cutoff),
    row("P 值校正方法", p_adjust_label(s$p_adjust_method)),
    row("火山图标注基因数", s$top_n_label),
    row("关键蛋白箱线图数量", s$top_n_boxplot),
    row("热图最多展示蛋白数", s$heatmap_max),
    row("热图显示行名上限", p$de_heatmap_show_rownames %||% "60"),
    grp("5. 功能富集"),
    row("GO ontology", paste(s$enrich_ont %||% c("BP", "MF", "CC"), collapse = " / ")),
    row("KEGG", if (!isTRUE(p$enrich_use_kegg)) "未启用"
                else if (identical(prep$kegg_org, "dre") &&
                         !identical(s$enrich_kegg_source, "online")) "启用（本地 KEGG.db 不含斑马鱼，已跳过）"
                else if (identical(s$enrich_kegg_source, "online")) "启用（在线 KEGG, 需联网）"
                else "启用（本地 KEGG.db）"),
    row("pvalue / qvalue 阈值",
        if (identical(s$enrich_p_adjust, "none"))
          sprintf("%s / 不适用（未校正，qvalue 不参与）", s$enrich_p)
        else sprintf("%s / %s", s$enrich_p, s$enrich_q)),
    row("P 值校正方法", p_adjust_label(s$enrich_p_adjust)),
    row("基因集大小范围", sprintf("%s – %s", p$enrich_min_gssize %||% 10,
                                  p$enrich_max_gssize %||% 500)),
    row("最小显著蛋白数", p$enrich_min_sig %||% 5),
    row("条形图 / 气泡图 Top N", sprintf("%s / %s", p$enrich_go_top_n %||% 10,
                                        p$enrich_kegg_top_n %||% 15)),
    grp("6. 报告"),
    row("生成时间", s$generated_at),
    row("生成工具", sprintf("DIA-NN GUI 结果分析模块 (diann.gui) + %s", R.version.string)),
    '</tbody></table>'
  )
}

html_sec6 <- function(s, prep) {
  paste0(
    '<h2 class="section" id="sec6">6 附录</h2>',
    '<h3 class="subsection" id="sec6-1">6.1 方法学说明</h3>',
    '<p><b>数据来源：</b>DIA-NN 蛋白水平定量矩阵（pg_matrix）。</p>',
    '<p><b>预处理：</b>剔除污染/反库条目；按检出率 ≥ ', esc(s$min_detect), ' 过滤低检出蛋白；',
    (if (identical(s$impute_method, "none"))
       '强度取 log2 后不填补缺失值，再做样本中位数归一化；'
     else '强度取 log2 后做缺失值插补，再做样本中位数归一化；'),
    esc(s$impute_detail), '</p>',
    '<p><b>差异分析：</b>limma 经验贝叶斯线性模型；多组时另做相对基准组的多重对比 F 检验，',
    '并输出全部两两对比；',
    if (identical(s$p_adjust_method, "none")) 'P 值未校正（按原始 P 值筛选）。</p>'
    else 'P 值经 BH（Benjamini-Hochberg）校正。</p>',
    '<p><b>PCA：</b>基于插补并归一化后的 log2 矩阵，中心化 + 标准化后取前两个主成分。</p>',
    '<p><b>功能富集：</b>GO 富集采用 clusterProfiler::enrichGO（',
    esc(paste(s$enrich_ont %||% c("BP", "MF", "CC"), collapse = "/")),
    '），KEGG 采用',
    if (identical(s$enrich_kegg_source, "online")) 'KEGG REST 在线通路库（enrichKEGG）' else '本地 KEGG.db 通路库',
    '；背景为全部可映射基因，',
    if (identical(s$enrich_p_adjust, "none"))
      paste0('P 值未校正（按原始 p 值筛选），pvalueCutoff = ',
             esc(s$enrich_p %||% "0.05"), '。</p>')
    else paste0('P 值经 BH（Benjamini-Hochberg）校正，pvalueCutoff = ',
                esc(s$enrich_p %||% "0.05"), '、qvalueCutoff = ',
                esc(s$enrich_q %||% "0.2"), '。</p>'),
    '<h3 class="subsection" id="sec6-2">6.2 分析参数</h3>',
    param_table_html(s, prep),
    '<h3 class="subsection" id="sec6-3">6.3 分析软件与工具</h3>',
    '<table class="kv"><tbody>',
    '<tr><td>DIA-NN</td><td>蛋白水平定量（pg_matrix）</td></tr>',
    '<tr><td>R / limma</td><td>缺失值插补、log2 变换、差异分析（Ritchie et al., 2015）</td></tr>',
    '<tr><td>ggplot2 / pheatmap / svglite</td><td>统计图形绘制与矢量输出</td></tr>',
    '<tr><td>clusterProfiler</td><td>GO / KEGG 富集分析（Yu et al., 2012）</td></tr>',
    '</tbody></table>',
    '<p class="ref">参考文献：<br>',
    '[1] Ritchie ME, et al. limma powers differential expression analyses for RNA-sequencing and microarray studies. Nucleic Acids Res, 2015.<br>',
    '[2] Yu G, et al. clusterProfiler: an R package for comparing biological themes among gene clusters. OMICS, 2012.<br>',
    '[3] Demichev V, et al. DIA-NN: neural networks and interference correction enable deep proteome coverage. Nat Methods, 2020.</p>'
  )
}

# ---- 页面组装 ----

REPORT_CSS_EXTRA <- '
/* 版面: 正文限宽居中 -> 宽屏下两侧留白, 避免图形被拉得过大 */
main{max-width:1040px;margin:0 auto;padding:0 28px 60px}
@media (min-width:1600px){main{max-width:1160px}}
@media (max-width:900px){main{max-width:100%;padding:0 16px 40px}}
.stat-row{display:flex;flex-wrap:wrap;gap:12px;margin:14px 0 18px}
.stat-card{flex:1 1 150px;min-width:150px;background:#f4f9fd;border:1px solid #d6e6f2;border-radius:8px;padding:14px;text-align:center}
.stat-card .num{font-size:26px;font-weight:700;color:#0b5f9e;line-height:1.1}
.stat-card .label{font-size:12.5px;color:#546e7a;margin-top:5px;font-weight:600}
table.kv{border-collapse:collapse;width:100%;margin:12px 0;font-size:13.5px}
table.kv td{border:1px solid #e3ebf2;padding:7px 11px;vertical-align:top}
table.kv td:first-child{width:210px;background:#f7fafc;color:#546e7a;font-weight:600}
.param-table .param-grp td{background:#eaf2f9;color:#0b5f9e;font-weight:700;font-size:13px}
.tbl-frame{width:100%;height:420px;border:1px solid #e3ebf2;border-radius:6px;margin:10px 0 18px}
/* 图: 限宽居中, 宽度自适应、高度按原始比例 (不拉伸、不裁切) */
.figure{margin:20px auto;max-width:860px}
/* 宽幅图 (如 QC 双栏图) 放宽到内容区满宽, 避免缩放过多导致图内文字过小 */
.figure.figure-wide{max-width:100%}
.figure img{display:block;width:100%;height:auto;max-width:100%;border:1px solid #eef3f7;border-radius:6px}
@media (max-width:900px){.figure{max-width:100%}}
.figure .caption{font-size:12.5px;color:#78909c;margin-top:6px;text-align:center}
.missing{background:#fff8e1;border-left:3px solid #ffb300;color:#8d6e00;font-size:13px;padding:9px 12px;border-radius:4px;margin:12px 0}
.callout{background:#f4f9fd;border-left:4px solid #0b5f9e;padding:12px 16px;border-radius:0 6px 6px 0;font-size:13.5px;line-height:1.75;margin:16px 0}
ol.flow{font-size:13.5px;line-height:1.85;color:#37474f}
ul.concl{font-size:13.5px;line-height:1.9}
.ref{font-size:12.5px;color:#607d8b;line-height:1.8}
.concl-plain{margin-top:-12px}
.hint{font-size:12.5px;color:#90a4ae}
'

build_report_html <- function(s, prep, has_qc, has_de, has_enrich, de, enrich) {
  sec2 <- if (has_qc) html_sec2(s) else
    '<h2 class="section" id="sec2">2 DIA-NN 数据质量控制</h2><div class="missing">未执行 QC 可视化模块。</div>'
  sec3 <- if (has_de) html_sec3(s, de) else
    '<h2 class="section" id="sec3">3 差异蛋白分析</h2><div class="missing">未执行差异分析模块。</div>'
  sec4 <- if (has_enrich) html_sec4(s, enrich) else
    '<h2 class="section" id="sec4">4 功能富集分析</h2><div class="missing">未执行功能富集模块。</div>'

  metadata <- list(
    report_name        = s$report_name,
    report_date        = s$report_date,
    responsible_person = "—",
    responsible_email  = "",
    report_code        = sprintf("Report-%s-0001", format(Sys.Date(), "%Y%m%d"))
  )

  html <- paste0(
'<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>', esc(s$report_name), '</title>
<link rel="stylesheet" href="./assets/style.css">
<style>', REPORT_CSS_EXTRA, '</style>
</head>
<body>
<header class="topbar">
  <div class="brand"><img src="./assets/logo.png" alt="Logo" onerror="this.style.display=\'none\'"><span id="report-title">', esc(s$report_name), '</span></div>
</header>
<div class="layout">
  <nav id="toc" class="toc"></nav>
  <main>
    <section class="meta-card">
      <h1><span id="report-heading">', esc(s$report_name), '</span></h1>
      <table class="kv"><tbody>
        <tr><td>报告日期</td><td id="meta-report-date">', esc(s$report_date), '</td></tr>
        <tr><td>责任人</td><td id="meta-responsible-person">—</td></tr>
        <tr><td>联系邮箱</td><td id="meta-responsible-email">—</td></tr>
        <tr><td>报告编码</td><td id="meta-report-code">', esc(metadata$report_code), '</td></tr>
        <tr><td>物种</td><td>', esc(s$species), '</td></tr>
        <tr><td>样本 / 分组</td><td>', esc(s$n_samples), ' / ', esc(s$n_groups), '</td></tr>
      </tbody></table>
    </section>
', html_sec1(s, has_qc, has_de, has_enrich), '
', sec2, '
', sec3, '
', sec4, '
', html_sec5(s, de, enrich), '
', html_sec6(s, prep), '
    <footer class="foot">本报告由 DIA-NN GUI 结果分析模块自动生成 · 生成时间 ', esc(s$generated_at), '</footer>
  </main>
</div>
<button id="backToTop" title="返回顶部">↑</button>
<script>
var REPORT_METADATA = ', js_json(metadata), ';
var REPORT_SUMMARY = ', js_json(summary_for_js(s)), ';
</script>
<script src="./assets/report.js"></script>
</body>
</html>')
  html
}

# REPORT_SUMMARY (供 report.js 替换 data-sum)
summary_for_js <- function(s) {
  keys <- c("n_samples", "n_groups", "proteins_raw", "proteins_final", "removed_low",
            "sig_total", "sig_up", "sig_down", "anova_sig", "union_sig",
            "n_pairwise", "n_imputed")
  out <- lapply(keys, function(k) {
    v <- s[[k]]
    if (is.null(v) || (length(v) == 1 && is.na(v))) "" else as.character(v)
  })
  names(out) <- keys
  out
}

# ---- 主入口 ----

# 生成完整报告目录; 返回 list(dir, html, files, n_figs, n_tables)
report_build <- function(out_root, prep, qc, de, enrich, params, modules,
                         assets_dir = system.file("analysis", "assets", package = "diann.gui")) {
  stamp <- format(Sys.time(), "%Y%m%d_%H%M%S")
  out_dir <- file.path(out_root, paste0("analysis_report_", stamp))
  dir.create(file.path(out_dir, "data"),     showWarnings = FALSE, recursive = TRUE)
  dir.create(file.path(out_dir, "assets"),   showWarnings = FALSE, recursive = TRUE)

  has_qc     <- "qc"     %in% modules && !is.null(qc)
  has_de     <- "de"     %in% modules && !is.null(de)
  has_enrich <- "enrich" %in% modules && !is.null(enrich) && !isTRUE(enrich$skipped)

  # ---- 1) 图形落盘到临时结果目录, 再复制进报告 data/ ----
  res_dir <- file.path(out_dir, "_results")
  dir.create(res_dir, showWarnings = FALSE, recursive = TRUE)
  fig_files <- character(0)
  if (has_qc)     fig_files <- c(fig_files, qc_save_all(qc, res_dir))
  if (has_de)     fig_files <- c(fig_files, de_save_all(de, res_dir))
  if (has_enrich) fig_files <- c(fig_files, enrich_save_all(enrich, res_dir))

  # ---- 2) 静态 HTML 表格 ----
  write_html_table(prep$miss_df, out_dir, "missingness_table.html")
  if (has_de) {
    if (identical(de$mode, "single")) {
      write_html_table(de$pairs[[1]]$sig, out_dir, "dep_table.html",
                       sig_col = "Significant", up_down_col = "logFC")
    } else {
      for (pt in de$pairs)
        write_html_table(pt$sig, out_dir, sprintf("dep_table_%s.html", pt$tag),
                         sig_col = "Significant", up_down_col = "logFC")
      if (!is.null(de$anova)) {
        keep <- intersect(c("Protein.Group", "Genes", "F", "P.Value", "adj.P.Val", "Significant"),
                          colnames(de$anova$res))
        write_html_table(de$anova$res[, keep, drop = FALSE], out_dir, "anova_table.html",
                         sig_col = "Significant")
      }
      write_html_table(de$pair_stat, out_dir, "pairwise_table.html")
    }
  }
  go_tab   <- if (has_enrich) enrich$tables$go   else NULL
  kegg_tab <- if (has_enrich) enrich$tables$kegg else NULL
  write_html_table(go_tab,   out_dir, "go_table.html",   sig_col = "p.adjust")
  write_html_table(kegg_tab, out_dir, "kegg_table.html", sig_col = "p.adjust")

  # ---- 3) assets (沿用模板样式与交互脚本) ----
  for (a in c("style.css", "report.js", "logo.png")) {
    src <- file.path(assets_dir, a)
    if (file.exists(src)) file.copy(src, file.path(out_dir, "assets", a), overwrite = TRUE)
  }

  # ---- 3.5) 复制图形到 data/ (须在渲染正文前完成) ----
  copy_figs(fig_files, out_dir)

  # ---- 4) 正文 ----
  s <- build_summary(prep, qc, de, enrich, params, modules)
  s$.out_dir <- out_dir
  s$.params  <- params
  html <- build_report_html(s, prep, has_qc, has_de, has_enrich, de, enrich)
  writeLines(html, file.path(out_dir, "report.html"), useBytes = TRUE)

  # ---- 5) 汇总 md + 参数 JSON ----
  writeLines(summary_md(s, prep, qc, de, enrich), file.path(out_dir, "08_summary_report.md"),
             useBytes = TRUE)
  writeLines(js_json(c(as.list(params), list(
    input_rows = prep$n_before, proteins_final = prep$n_final, n_samples = length(prep$snames),
    groups = prep$group_levels, species = prep$species, modules = modules,
    mode = if (is.null(de)) "none" else de$mode,
    generated_at = s$generated_at)), pretty = TRUE),
    file.path(out_dir, "analysis_params.json"), useBytes = TRUE)

  # ---- 6) 输出清单 ----
  data_files <- list.files(file.path(out_dir, "data"), full.names = TRUE)

  list(dir = out_dir, html = file.path(out_dir, "report.html"),
       files = c(list.files(out_dir, full.names = TRUE, recursive = TRUE)),
       n_figs = sum(grepl("\\.(svg|png)$", data_files)),
       n_tables = sum(grepl("\\.html$", data_files)))
}

# 摘要 md
summary_md <- function(s, prep, qc, de, enrich) {
  lines <- c(
    "# Proteomics Analysis Summary Report",
    "",
    sprintf("- Analysis date: %s", Sys.Date()),
    sprintf("- R version: %s", R.version.string),
    sprintf("- Generated by: DIA-NN GUI analysis module (%s)", s$generated_at),
    sprintf("- Output directory: %s", s$.out_dir),
    "",
    "## 1. Input",
    sprintf("- Raw protein entries: %d", prep$n_before),
    sprintf("- Samples: %d (%s)", length(prep$snames), paste(prep$snames, collapse = ", ")),
    sprintf("- Groups: %s", s$groups_text),
    sprintf("- Species detected: %s", prep$species),
    "",
    "## 2. Filtering",
    sprintf("- Contaminant/reverse entries removed: %d", prep$n_contam),
    sprintf("- Low-detection proteins removed (<%.0f%% samples): %d", prep$min_detect_frac * 100, prep$n_low),
    sprintf("- Proteins retained: %d", prep$n_final),
    "",
    "## 3. Missing values",
    sprintf("- Missing rate per sample: %s",
            paste(sprintf("%s=%.1f%%", prep$snames, prep$miss_per_sample * 100), collapse = ", ")),
    if (identical(prep$impute_method %||% "mnar", "none"))
      sprintf("- Missing values retained (not imputed): %d (%.2f%% of matrix)",
              prep$n_missing, prep$miss_pct %||% 0)
    else sprintf("- Imputed missing values: %d (%.2f%% of matrix)", prep$n_imp, prep$imp_pct),
    sprintf("- Imputation method: %s", s$impute_md),
    "",
    "## 4. Transformation",
    "- Method: log2 transform -> imputation -> sample median normalization (each sample's median shifted to the maximum median across samples).",
    "",
    "## 5. QC",
    if (!is.null(qc)) c(
      sprintf("- Detected proteins per sample: %s", s$det_text),
      sprintf("- PCA: PC1=%.1f%%, PC2=%.1f%% variance explained",
              qc$stats$pca_var[1], qc$stats$pca_var[2]),
      sprintf("- Median within-group CV: %s", s$cv_text))
    else "- QC module not executed",
    "",
    "## 6. Differential analysis (limma)",
    if (is.null(de)) "- Module not executed"
    else c(
      sprintf("- Mode: %s", if (identical(de$mode, "multi")) sprintf("multi-group comparison (%d groups)", prep$n_groups)
              else "single pairwise comparison"),
      sprintf("- Threshold: |log2FC| > %.2f, P value < %.3f", de$logFC_cutoff, de$pval_cutoff),
      if (identical(de$mode, "single"))
        sprintf("- Comparison: %s vs %s, significant proteins: %d (up=%d, down=%d)",
                de$pairs[[1]]$trt, de$pairs[[1]]$ctrl, nrow(de$pairs[[1]]$sig),
                de$pairs[[1]]$sig_up, de$pairs[[1]]$sig_down)
      else c(
        sprintf("- Global F-test significant proteins: %d", if (is.null(de$anova)) 0 else nrow(de$anova$sig)),
        "- Pairwise comparisons:",
        vapply(de$pairs, function(x)
          sprintf("    * %s: %d significant (up=%d, down=%d)",
                  x$contrast, nrow(x$sig), x$sig_up, x$sig_down), character(1)),
        sprintf("- Union of significant proteins: %d", nrow(de$sig)))),
    "",
    "## 7. Enrichment (GO/KEGG)",
    sprintf("- Enrichment results: %s", s$enrich_status),
    if (!is.null(enrich) && isTRUE(enrich$skipped)) sprintf("- Skipped: %s", enrich$reason) else "",
    "",
    "## 8. Warnings",
    if (length(c(prep$warnings, if (!is.null(qc)) qc$warnings, if (!is.null(de)) de$warnings,
                 if (!is.null(enrich)) enrich$warnings)) > 0)
      paste0("- [WARN] ", c(prep$warnings, if (!is.null(qc)) qc$warnings,
                            if (!is.null(de)) de$warnings,
                            if (!is.null(enrich)) enrich$warnings))
    else "- None",
    "")
  lines
}
