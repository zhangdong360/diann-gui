# ============================================================
# analysis-plot.R — 结果分析·绘图共享层 (移植自 mass_analysis/core_plot.R)
#
# 统一配色 / 主题 / 画布 / new_plot 对象 / 预览与落盘。
# 预览 (内联 SVG data URI) 与落盘 (svglite) 走完全相同的绘制路径,
# 界面所见即报告所得。5 条红线 (踩过坑, 勿改):
#   1. 不要改回 renderPlot + plotOutput 的位图预览 (缩放即模糊, 与报告不一致);
#   2. 不要给 renderPlot 传函数式 width/height 去读窗口宽度 (单位必须是像素,
#      返回英寸会把画布变成个位数像素, 动态测量还易引发重建循环);
#   3. 不要给 .plot-box 设 max-height / overflow:auto (高图被裁切);
#   4. 不要给 img 加 aspect-ratio / object-fit (与 SVG 自身比例冲突);
#   5. 不要用 readChar/paste 拼 base64 (中文 locale 乱码),
#      统一 jsonlite::base64_enc(readBin(path, "raw", n))。
# 所有 ggplot2/svglite 等调用在函数体内命名空间限定 + 运行时检查 (analysis-deps.R),
# 包加载期不依赖任何绘图包。
# ============================================================

# 上/下调配色
PAL_UPDN <- c("Up" = "#D9534F", "Down" = "#3B6FB5", "NS" = "#B0B0B0")

# 分组配色 (超出固定色板时按 hcl 扩展)
get_group_colors <- function(n) {
  base <- c("#3B6FB5", "#D9534F", "#4DAF4A", "#FF7F0E", "#9467BD", "#17BECF",
            "#8C564B", "#E377C2", "#BCBD22", "#7F7F7F",
            "#AEC7E8", "#FF9896", "#98DF8A", "#C5B0D5", "#FFBB78")
  if (n <= length(base)) return(base[seq_len(n)])
  grDevices::hcl(h = seq(0, 360, length.out = n + 1)[seq_len(n)], c = 80, l = 60)
}

# 统一主题 (惰性求值: 首次调用才触达 ggplot2, 并缓存)
.an_theme_cache <- new.env(parent = emptyenv())
theme_proteo <- function() {
  if (!is.null(.an_theme_cache$th)) return(.an_theme_cache$th)
  th <- ggplot2::theme_bw(base_size = 13, base_family = "sans") +
    ggplot2::theme(plot.title    = ggplot2::element_text(face = "bold", size = 15, hjust = 0.5,
                                                         margin = ggplot2::margin(b = 8)),
                   plot.subtitle = ggplot2::element_text(size = 11, hjust = 0.5, colour = "grey30"),
                   axis.title    = ggplot2::element_text(size = 12.5),
                   axis.text     = ggplot2::element_text(size = 11, colour = "grey20"),
                   legend.title  = ggplot2::element_text(size = 11, face = "bold"),
                   legend.text   = ggplot2::element_text(size = 10.5),
                   panel.grid.minor = ggplot2::element_blank(),
                   panel.border = ggplot2::element_rect(colour = "grey40", fill = NA, linewidth = 0.8),
                   strip.background = ggplot2::element_rect(fill = "grey92", colour = "grey60"),
                   strip.text = ggplot2::element_text(face = "bold", size = 11.5))
  .an_theme_cache$th <- th
  th
}

# 热图几何: 按行数给 cellheight 与设备高
hm_layout <- function(n_rows) {
  cell <- if (n_rows <= 40) 12 else if (n_rows <= 120) 8 else 5
  mat  <- n_rows * cell / 72          # pheatmap cell 单位为 pt，1in=72pt
  top  <- 1.5                          # 顶部估计高度(in)
  bot  <- 0.7
  list(cell = cell, height = max(top + mat + bot, 2.2))
}

# 按样本数自适应的轴标签/柱体样式 (QC 与预处理共用)
sample_axis_style <- function(n) {
  n <- max(as.integer(n), 1L)
  list(
    angle   = if (n <= 8) 0 else if (n <= 16) 35 else 60,
    hjust   = if (n <= 8) 0.5 else 1,
    text_sz = if (n <= 8) 9.5 else if (n <= 16) 8 else 6.8,
    bar_lab = if (n <= 12) 3.2 else if (n <= 24) 2.6 else 2.0,
    bar_w   = if (n <= 8) 0.7 else if (n <= 20) 0.8 else 0.9,
    width   = if (n <= 16) 11 else 13                       # in
  )
}

# 统一绘图对象: 预览与落盘走同一路径; kind = ggplot / grid / base
new_plot <- function(draw, kind = c("ggplot", "grid", "base"), width = 8, height = 6, label = "") {
  list(draw = draw, kind = match.arg(kind), width = width, height = height, label = label)
}

draw_plot <- function(p) {
  stopifnot(is.list(p), is.function(p$draw))
  switch(p$kind,
         ggplot = print(p$draw()),
         grid   = grid::grid.draw(p$draw()),
         base   = p$draw())
  invisible(p)
}

# 文件输出: svg_to_file (预览与报告共用) / png_to_file (300dpi 降级)
svg_to_file <- function(p, path, width = NULL, height = NULL) {
  stopifnot(is.list(p), is.function(p$draw))
  width  <- width  %||% p$width
  height <- height %||% p$height
  svglite::svglite(path, width = width, height = height)
  on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)  # 保证设备关闭, 释放文件锁
  draw_plot(p)
  invisible(path)
}

png_to_file <- function(p, path, width = NULL, height = NULL, res = 300) {
  stopifnot(is.list(p), is.function(p$draw))
  width  <- width  %||% p$width
  height <- height %||% p$height
  grDevices::png(path, width = width, height = height, units = "in", res = res)
  on.exit(try(grDevices::dev.off(), silent = TRUE), add = TRUE)
  draw_plot(p)
  invisible(path)
}

# 保存图形: SVG 优先, 失败降级 PNG; 返回实际路径
save_plot_obj <- function(p, out_dir, file_stem, width = NULL, height = NULL) {
  svg_path <- file.path(out_dir, paste0(file_stem, ".svg"))
  png_path <- file.path(out_dir, paste0(file_stem, ".png"))

  ok <- tryCatch({
    svg_to_file(p, svg_path, width, height)
    TRUE
  }, error = function(e) {
    warning(paste0("SVG 输出失败 (", conditionMessage(e), ")，降级为 300dpi PNG: ", file_stem))
    try(grDevices::dev.off(), silent = TRUE)
    if (file.exists(svg_path)) try(file.remove(svg_path), silent = TRUE)
    FALSE
  })
  if (!ok) {
    tryCatch(png_to_file(p, png_path, width, height), error = function(e) {
      warning("PNG 输出失败: ", file_stem, " (", conditionMessage(e), ")")
      try(grDevices::dev.off(), silent = TRUE)
    })
    return(png_path)
  }
  svg_path
}

# 安全取图: list[[NULL]] 会报错, 无效 key 退回第一张
pick_plot <- function(plots, nm) {
  if (is.null(plots) || length(plots) == 0) return(NULL)
  if (is.null(nm) || length(nm) != 1L || is.na(nm) || !(nm %in% names(plots)))
    return(plots[[1]])
  plots[[nm]]
}

# 文件 -> base64 data URI
file_to_data_uri <- function(path, mime) {
  n <- file.info(path)$size
  paste0("data:", mime, ";base64,", jsonlite::base64_enc(readBin(path, "raw", n = n)))
}

figure_ui <- function(p, width = NULL, height = NULL) {
  err <- NULL

  svg_tmp <- tempfile(fileext = ".svg")
  on.exit(unlink(svg_tmp), add = TRUE)
  src <- tryCatch({
    svg_to_file(p, svg_tmp, width, height)
    file_to_data_uri(svg_tmp, "image/svg+xml")
  }, error = function(e) {
    err <<- conditionMessage(e)
    try(grDevices::dev.off(), silent = TRUE)
    NULL
  })

  if (is.null(src)) {
    png_tmp <- tempfile(fileext = ".png")
    on.exit(unlink(png_tmp), add = TRUE)
    src <- tryCatch({
      png_to_file(p, png_tmp, width, height)
      file_to_data_uri(png_tmp, "image/png")
    }, error = function(e) {
      err <<- conditionMessage(e)
      try(grDevices::dev.off(), silent = TRUE)
      NULL
    })
  }

  if (is.null(src))
    return(htmltools::div(class = "err-box",
                          paste0("图形渲染失败: ", err %||% "未知错误")))
  htmltools::tags$img(src = src, alt = p$label %||% "")
}

plot_box <- function(output_id, p) {
  if (is.null(p)) return(NULL)
  htmltools::div(class = "plot-box", shiny::uiOutput(output_id))
}

render_plot_svg <- function(get_plot) {
  shiny::renderUI({
    p <- get_plot()
    if (is.null(p)) return(NULL)
    figure_ui(p)
  })
}

# 组合图: 按设计尺寸出图, 与报告比例一致
render_plot_inline_svg <- function(draw_fn, width = 8, height = 6, label = "",
                                   width_fn = NULL) {
  shiny::renderUI({
    # width_fn: 可选, 按数据规模动态取画布宽度 (如样本多时加宽)
    w <- if (is.function(width_fn)) width_fn() else width
    if (!is.numeric(w) || length(w) != 1 || !is.finite(w) || w <= 0) w <- width
    figure_ui(new_plot(draw_fn, kind = "base", width = w, height = height, label = label))
  })
}
