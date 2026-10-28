# ============================================================
# mod-analysis.R — 结果分析模块服务端
# 编排移植自 mass_analysis/app.R: raw -> 分组/批次 -> prep -> qc/de/enrich -> report;
# 分组表/批次表交互移植自其 mod_data.R (DT 单元格编辑 + 批量粘贴),
# 报告生成/打包移植自 mod_report.R (zip::zipr, 排除 _results/)。
#
# 与上传式原版的差异: 矩阵经服务端路径读取; 父级可用 matrix_req 带入路径
# (M3 任务队列「进入下游分析」联动), 并可指定打开的子页签。
# ============================================================

# ---- 粘贴两列文本解析 (Tab/逗号/分号/空白); err 非空表示不可用 ----
an_parse_pairs_paste <- function(txt, ids, what = "分组") {
  lines <- trimws(strsplit(as.character(txt %||% ""), "\r?\n")[[1]])
  lines <- lines[nzchar(lines)]
  if (length(lines) == 0)
    return(list(err = sprintf("请粘贴「样本名 + %s」两列内容。", what)))
  sp <- lapply(lines, function(l) {
    p <- strsplit(l, "[,\t;]+")[[1]]
    if (length(p) < 2) p <- strsplit(trimws(l), "[[:space:]]+")[[1]]
    trimws(p)
  })
  bad <- vapply(sp, function(p) length(p) < 2, logical(1))
  if (any(bad))
    return(list(err = sprintf("第 %d 行无法解析出两列（样本名、%s）。", which(bad)[1], what)))
  m <- data.frame(Key = vapply(sp, `[`, character(1), 1),
                  Val = vapply(sp, `[`, character(1), 2),
                  stringsAsFactors = FALSE)
  miss <- setdiff(ids, m$Key)
  if (length(miss) > 0)
    return(list(err = sprintf("以下 %d 个样本未在粘贴内容中：%s%s", length(miss),
                              paste(utils::head(miss, 5), collapse = ", "),
                              if (length(miss) > 5) " …" else "")))
  extra <- setdiff(m$Key, ids)
  m <- m[match(ids, m$Key), , drop = FALSE]
  list(df = m,
       note = if (length(extra) > 0)
         sprintf("已忽略不属于本数据集的 %d 个样本", length(extra)) else NULL)
}

# ---- 报告输出目录校验: 返回 NULL 或原因 ----
an_report_prepare_dir <- function(d) {
  if (!nzchar(d)) return("输出目录为空。")
  if (file.exists(d) && !dir.exists(d)) return(sprintf("该路径已存在且不是文件夹：%s", d))
  ok <- tryCatch({ dir.create(d, showWarnings = FALSE, recursive = TRUE); dir.exists(d) },
                 error = function(e) FALSE)
  if (!isTRUE(ok)) return(sprintf("无法创建输出目录（请检查路径与权限）：%s", d))
  probe <- file.path(d, sprintf(".an_write_test_%s", format(Sys.time(), "%H%M%OS3")))
  writable <- tryCatch({ file.create(probe); file.exists(probe) }, error = function(e) FALSE)
  if (!isTRUE(writable)) return(sprintf("输出目录不可写：%s", d))
  unlink(probe)
  NULL
}

# ---- 打包 zip (mirror 保留子目录, 排除 _results/); 返回 NULL 或原因 ----
an_report_make_zip <- function(dir, zipfile) {
  if (!dir.exists(dir)) return(sprintf("报告目录不存在：%s", dir))
  if (!requireNamespace("zip", quietly = TRUE))
    return("未安装 zip 包，无法打包（install.packages(\"zip\")）；可先用「新窗口打开」查看/另存。")
  files <- list.files(dir, recursive = TRUE)
  files <- files[!grepl("^_results(/|$)", files)]
  if (length(files) == 0) return("报告目录为空，无内容可打包。")
  err <- NULL
  ok <- tryCatch({
    old <- setwd(dir)
    on.exit(setwd(old), add = TRUE)
    zip::zipr(zipfile, files = files, mode = "mirror")
    TRUE
  }, error = function(e) { err <<- conditionMessage(e); FALSE },
     warning = function(w) { err <<- conditionMessage(w); FALSE })
  if (!isTRUE(ok))
    return(sprintf("打包 zip 失败：%s", err %||% "未知原因"))
  if (!file.exists(zipfile) || file.size(zipfile) == 0)
    return("打包 zip 失败：生成的压缩包为空。")
  NULL
}

# DT 单元格编辑载荷并入表 (row 1-based, col 为 0-based JS 列索引; 按列名写入)
an_merge_cell_edit <- function(df, info, col_name) {
  if (is.null(info) || !all(c("row", "value") %in% names(info))) return(df)
  r <- suppressWarnings(as.integer(info$row))
  v <- as.character(info$value)
  ok <- !is.na(r) & r >= 1L & r <= nrow(df) & !is.na(v)
  if (any(ok)) df[[col_name]][r[ok]] <- v[ok]
  df
}

# ============================================================
# 模块主体
# ============================================================
mod_analysis_server <- function(id, volumes, matrix_req = reactive(NULL)) {
  moduleServer(id, function(input, output, session) {
    ns <- session$ns
    has_dt <- requireNamespace("DT", quietly = TRUE)

    an_notify <- function(msg, type = "message", dur = 8)
      showNotification(msg, type = type, duration = dur)

    # ---------------- 依赖门禁 ----------------
    dep_gate_ui <- function(groups, label) {
      renderUI({
        df <- an_deps_check(groups)
        miss <- df[!df$installed, , drop = FALSE]
        if (!nrow(miss)) return(NULL)
        hints <- an_deps_install_hint(miss$pkg, miss$bioc)
        div(class = "an-err", icon("plug-circle-exclamation"),
            sprintf("%s 缺少依赖包：%s。请在 R 中执行：%s", label,
                    paste(miss$pkg, collapse = ", "),
                    paste(hints, collapse = "；")))
      })
    }
    output$deps_alert <- renderUI({
      st <- an_deps_status()
      if (st$ok) return(NULL)
      tagList(div(class = "an-err", icon("plug-circle-exclamation"),
        sprintf("结果分析模块缺少 %d 个依赖包：%s。", length(st$missing_pkgs),
                paste(st$missing_pkgs, collapse = ", ")),
        tags$br(), "安装命令（可复制）:",
        tags$code(paste(st$hints, collapse = "；")),
        tags$br(), tags$span(class = "an-hint",
          "可选增强: ", paste(paste0(names(an_deps_optional()), " (", an_deps_optional(), ")"),
                              collapse = "；"))))
    })
    output$qc_gate     <- dep_gate_ui("qc", "QC 可视化")
    output$de_gate     <- dep_gate_ui("de", "差异分析")
    output$enrich_gate <- dep_gate_ui("enrich", "功能富集")

    # ---------------- 矩阵读取 ----------------
    shinyFileChoose(input, "matrix_pick", roots = volumes,
                    filetypes = c("tsv", "txt", "csv"))
    observeEvent(input$matrix_pick, {
      p <- shinyFiles::parseFilePaths(volumes, input$matrix_pick)
      if (length(p$datapath)) updateTextInput(session, "matrix_path",
                                              value = as.character(p$datapath))
    })

    # 待读取路径: 点「读取矩阵」或父级 matrix_req 带入 (M3 联动)
    load_path <- reactiveVal(NULL)
    observeEvent(input$matrix_load, {
      f <- trimws(input$matrix_path %||% "")
      if (!nzchar(f)) { an_notify("请先填写矩阵文件路径。", "error"); return() }
      load_path(f)
    })
    observeEvent(matrix_req(), {
      mr <- matrix_req(); req(mr)
      updateTextInput(session, "matrix_path", value = mr$path)
      load_path(mr$path)
      if (!is.null(mr$tab)) updateTabsetPanel(session, "an_tabs", selected = mr$tab)
    }, ignoreNULL = TRUE)

    raw_data <- reactive({
      f <- load_path(); req(f)
      if (!file.exists(f)) {
        an_notify(sprintf("文件不存在: %s", f), "error", 10)
        return(NULL)
      }
      tryCatch(read_input_file(f), error = function(e) {
        an_notify(paste("矩阵读取失败:", conditionMessage(e)), "error", 10)
        NULL
      })
    })

    src_of <- reactive(input$source %||% "diann")

    output$matrix_info <- renderUI({
      if (is.null(load_path()))
        return(div(class = "an-hint", "尚未读取矩阵。"))
      raw <- raw_data()
      if (is.null(raw))
        return(div(class = "an-err", icon("triangle-exclamation"), " 矩阵不可用 (见上方提示)。"))
      am <- auto_annot_cols(colnames(raw), src_of())
      n_annot <- sum(!is.na(unlist(am)))
      div(class = "an-ok", icon("circle-check"),
          sprintf("已读取 %s：%d 行 × %d 列（识别 %d 个注释列, %d 个样本列）",
                  basename(load_path()), nrow(raw), ncol(raw), n_annot, ncol(raw) - n_annot))
    })

    # ---------------- 数据与分组 ----------------
    group_map <- reactiveVal(NULL)
    batch_map <- reactiveVal(NULL)

    observeEvent(list(raw_data(), src_of()), {
      group_map(NULL); batch_map(NULL)
    }, ignoreNULL = TRUE)

    inferred <- reactive({
      raw <- raw_data(); req(raw)
      am <- auto_annot_cols(colnames(raw), src_of())
      used <- unlist(am[!is.na(unlist(am))])
      sc <- setdiff(colnames(raw), used)
      sn <- make.unique(sub("\\.[^.]+$", "", basename(sc)), sep = "_")
      # 与 resolve_groups() 共用 infer_groups, 保证界面与下游一致
      infer <- infer_groups(sn)
      ok <- !is.null(infer)
      if (!ok) infer <- sn   # 推断失败时保留原名, 由 validate 拒绝下游使用
      list(sample_cols = sc, snames = sn, infer = infer, ok = ok, annot_map = am)
    })

    output$data_page <- renderUI({
      if (!is.null(raw_data())) return(NULL)
      div(class = "an-card", style = "text-align:center;padding:48px 20px;",
        icon("file-arrow-up", class = "fa-3x"), h4("请先在上方填写并读取 pg_matrix 路径"),
        p(class = "an-hint", "DIA-NN 作业完成后, 可在「任务队列」页点「进入下游分析」自动带入。"))
    })
    output$dt_gate <- renderUI({
      if (has_dt) return(NULL)
      div(class = "an-err", icon("plug-circle-exclamation"),
          " 未安装 DT 包, 可编辑分组表不可用; 请用「批量填入分组…」粘贴设置分组",
          "（install.packages(\"DT\")）。")
    })

    group_rev <- reactiveVal(0L)
    batch_rev <- reactiveVal(0L)
    last_g_edit <- reactiveVal(NULL)
    last_b_edit <- reactiveVal(NULL)

    output$infer_status <- renderUI({
      inf <- inferred(); req(inf)
      if (inf$ok)
        div(class = "an-ok", icon("circle-check"),
            sprintf(" 自动推断成功：%d 个样本 → %d 组（%s）", length(inf$snames),
                    length(unique(inf$infer)), paste(unique(inf$infer), collapse = ", ")))
      else
        div(class = "an-err", icon("triangle-exclamation"),
            " 无法从列名自动推断分组，请在下表中手动填写每个样本的组名后点「应用分组」。")
    })

    current_map_df <- function(inf) {
      cur <- isolate(group_map())
      if (is.null(cur) || !is.data.frame(cur) ||
          !all(c("Sample", "Group") %in% colnames(cur)) ||
          nrow(cur) != length(inf$snames))
        return(data.frame(Sample = inf$snames, Group = inf$infer, stringsAsFactors = FALSE))
      data.frame(Sample = as.character(cur$Sample), Group = as.character(cur$Group),
                 stringsAsFactors = FALSE)
    }

    if (has_dt) {
      output$group_table <- DT::renderDT({
        group_rev()
        inf <- inferred()
        df <- current_map_df(inf)
        DT::datatable(df, rownames = FALSE, editable = list(target = "cell"),
                      options = list(dom = "t", paging = FALSE, ordering = FALSE,
                                     columnDefs = list(list(className = "dt-center",
                                                            targets = c(0, 1)))),
                      class = "compact stripe")
      }, server = FALSE)
      observeEvent(input$group_table_cell_edit, {
        group_map(an_merge_cell_edit(current_map_df(inferred()),
                                     input$group_table_cell_edit, "Group"))
        last_g_edit(input$group_table_cell_edit)
      })
    }

    an_validate_or_notify_map <- function(df) {
      df$Sample <- trimws(as.character(df$Sample))
      df$Group  <- trimws(as.character(df$Group))
      if (any(!nzchar(df$Sample))) { an_notify("样本名不能为空。", "error"); return(FALSE) }
      if (anyDuplicated(df$Sample) > 0) {
        an_notify(sprintf("样本名重复：%s",
                          paste(unique(df$Sample[duplicated(df$Sample)]), collapse = ", ")),
                  "error"); return(FALSE)
      }
      err <- validate_group_map(df)
      if (!is.null(err)) { an_notify(paste("分组无效：", err), "error"); return(FALSE) }
      TRUE
    }

    observeEvent(input$grp_apply, {
      inf <- inferred(); req(inf)
      df <- current_map_df(inf)
      e <- isolate(input$group_table_cell_edit)
      if (has_dt && !is.null(e) && !identical(e, isolate(last_g_edit()))) {
        df <- an_merge_cell_edit(df, e, "Group")
        last_g_edit(e)
      }
      if (!an_validate_or_notify_map(df)) return()
      group_map(df); group_rev(group_rev() + 1L)
      an_notify(sprintf("分组已应用：%d 组（%s）", length(unique(df$Group)),
                        paste(unique(df$Group), collapse = ", ")))
    })

    observeEvent(input$grp_reset, {
      inf <- inferred(); req(inf)
      if (!inf$ok) {
        group_map(NULL); group_rev(group_rev() + 1L)
        an_notify(paste0("无法从列名自动推断分组（需 ≥2 组且每组 ≥2 样本）。",
                         "请手动填写组名后点「应用分组」。"), "warning"); return()
      }
      df <- data.frame(Sample = inf$snames, Group = inf$infer, stringsAsFactors = FALSE)
      if (!an_validate_or_notify_map(df)) { group_map(NULL); return() }
      group_map(df); group_rev(group_rev() + 1L)
      an_notify(sprintf("已恢复为自动推断分组（%d 组）。", length(unique(df$Group))))
    })

    # 批量粘贴分组 (弹窗)
    observeEvent(input$open_group_paste, {
      inf <- inferred(); req(inf)
      showModal(modalDialog(
        title = "批量填入分组",
        div(class = "an-hint", "从 Excel 复制「样本名 + 分组」两列粘贴到下面（每行一个样本）。"),
        textAreaInput(ns("group_paste"), NULL, width = "100%", height = "150px",
                      placeholder = "样本名 <Tab/逗号/空格> 分组\n如：\nA1\tCtrl\nA2\tCtrl\nB1\tKO"),
        uiOutput(ns("group_paste_status")),
        easyClose = TRUE, size = "m",
        footer = tagList(
          actionButton(ns("group_paste_apply"), "填入分组表",
                       class = "btn-primary btn-sm", icon = icon("wand-magic-sparkles")),
          modalButton("关闭"))))
    })

    group_paste_df <- reactive({
      inf <- inferred(); req(inf)
      r <- an_parse_pairs_paste(input$group_paste, inf$snames, what = "分组")
      if (!is.null(r$err)) return(r)
      cur <- current_map_df(inf)
      list(df = data.frame(Sample = cur$Sample, Group = trimws(r$df$Val),
                           stringsAsFactors = FALSE), note = r$note)
    })

    output$group_paste_status <- renderUI({
      r <- group_paste_df(); req(r)
      if (!is.null(r$err))
        return(div(class = "an-err", icon("triangle-exclamation"), " ", r$err))
      err <- validate_group_map(r$df)
      div(class = if (is.null(err)) "an-ok" else "an-err",
          icon(if (is.null(err)) "circle-check" else "triangle-exclamation"), " ",
          sprintf("将得到 %d 个分组：%s", length(table(r$df$Group)),
                  paste(names(table(r$df$Group)), collapse = "、")),
          if (!is.null(err)) paste0("；", err) else "",
          if (!is.null(r$note)) paste0("；", r$note) else "")
    })

    observeEvent(input$group_paste_apply, {
      r <- group_paste_df(); req(r)
      if (!is.null(r$err)) { an_notify(paste("填入分组失败：", r$err), "error"); return() }
      group_map(r$df); group_rev(group_rev() + 1L)
      err <- validate_group_map(r$df)
      if (!is.null(err))
        an_notify(paste0("已填入分组表，但该分组暂不可用于下游：", err), "warning")
      else an_notify(sprintf("已填入 %d 个分组。", length(unique(r$df$Group))))
      removeModal()
    })

    # ---------------- 批次设置 (可选 ComBat) ----------------
    output$combat_block <- renderUI({
      if (!isTRUE(input$use_combat)) return(NULL)
      tagList(
        div(class = "an-hint",
            "要求 ≥2 个批次、每批 ≥2 个样本; ComBat 把「分组」作为协变量, 只去批次效应。",
            "若批次与分组完全混杂 (每批只含一组) 会被拒绝执行。"),
        fluidRow(
          column(4, selectInput(ns("bulk_mode"), "批量生成方式",
                                choices = c("粘贴 样本→批次 对照表" = "paste",
                                            "按顺序每批 N 个" = "seq"),
                                selected = "paste")),
          column(8, uiOutput(ns("bulk_opts")))
        ),
        actionButton(ns("bulk_apply"), "生成并填入批次表", class = "btn-primary btn-sm",
                     icon = icon("wand-magic-sparkles")),
        uiOutput(ns("bulk_preview"))
      )
    })
    output$bulk_opts <- renderUI({
      if (identical(input$bulk_mode %||% "paste", "seq")) {
        fluidRow(
          column(6, numericInput(ns("bulk_n"), "每批样本数", value = 6, min = 1, step = 1)),
          column(6, textInput(ns("bulk_prefix"), "批次名前缀", value = "Batch")))
      } else {
        textAreaInput(ns("bulk_paste"), NULL, width = "100%", height = "120px",
                      placeholder = "每行: 样本名 <Tab/逗号/空格> 批次\n如：\nA1\tRun1\nA2\tRun1\nB1\tRun2")
      }
    })
    bulk_df <- reactive({
      inf <- inferred(); req(inf)
      sn <- inf$snames
      if (identical(input$bulk_mode %||% "paste", "seq")) {
        n <- suppressWarnings(as.integer(input$bulk_n %||% 6))
        if (is.na(n) || n < 1) return(list(err = "「每批样本数」需为 ≥1 的整数。"))
        pf <- trimws(as.character(input$bulk_prefix %||% "")); if (!nzchar(pf)) pf <- "Batch"
        list(df = data.frame(Sample = sn, Batch = paste0(pf, ceiling(seq_along(sn) / n)),
                             stringsAsFactors = FALSE))
      } else {
        r <- an_parse_pairs_paste(input$bulk_paste, sn, what = "批次")
        if (!is.null(r$err)) return(r)
        list(df = data.frame(Sample = sn, Batch = r$df$Val, stringsAsFactors = FALSE),
             note = r$note)
      }
    })
    output$bulk_preview <- renderUI({
      r <- bulk_df(); req(r)
      if (!is.null(r$err))
        return(div(class = "an-err", icon("triangle-exclamation"), " ", r$err))
      df <- r$df; tb <- table(df$Batch)
      g  <- { gm <- group_map()
              if (!is.null(gm) && is.null(validate_group_map(gm)) &&
                  identical(as.character(gm$Sample), inferred()$snames))
                as.character(gm$Group) else inferred()$infer }
      g_ok <- length(g) == nrow(df) && length(unique(g)) >= 2 && all(table(g) >= 2)
      conf <- g_ok && all(vapply(split(g, df$Batch),
                                 function(x) length(unique(x)) == 1L, logical(1)))
      tagList(
        div(class = "an-ok", icon("circle-check"),
            sprintf(" 将生成 %d 个批次：%s%s", length(tb),
                    paste(sprintf("%s(%d)", names(tb), as.integer(tb)), collapse = "、"),
                    if (!is.null(r$note)) paste0("；", r$note) else "")),
        if (conf) div(class = "an-err", icon("triangle-exclamation"),
                      " 注意：批次与分组完全混杂，去批次会被拒绝；请改用与分组交叉的分批方式。"))
    })
    observeEvent(input$bulk_apply, {
      r <- bulk_df(); req(r)
      if (!is.null(r$err)) { an_notify(paste("批量设置失败：", r$err), "error"); return() }
      batch_map(r$df); batch_rev(batch_rev() + 1L)
      err <- validate_batch_map(r$df, inferred()$snames)
      if (!is.null(err))
        an_notify(paste0("已填入批次表，但暂不可用于去批次：", err), "warning")
      else an_notify(sprintf("已填入 %d 个批次。", length(unique(r$df$Batch))))
    })

    # ---------------- 数据预览 ----------------
    if (has_dt) {
      output$preview <- DT::renderDT({
        raw <- raw_data(); req(raw)
        d <- raw[seq_len(min(30, nrow(raw))), seq_len(min(12, ncol(raw))), drop = FALSE]
        DT::datatable(d, rownames = FALSE,
                      options = list(dom = "t", scrollX = TRUE, paging = FALSE),
                      class = "compact stripe")
      })
    }

    # ---------------- 对照选择 ----------------
    output$control_ui <- renderUI({
      pp <- tryCatch(prep(), error = function(e) NULL)
      lv <- if (is.null(pp)) character(0) else pp$group_levels
      if (length(lv) < 2) return(NULL)
      selectInput(ns("control_grp"), "对照组 (差异分析基准):",
                  choices = lv, selected = lv[1])
    })

    # ---------------- 预处理 (参数/分组/批次变化自动重算) ----------------
    global_params <- reactive(list(
      min_detect_frac  = input$min_detect_frac,
      min_group_detect = input$min_group_detect,
      impute_method    = input$impute_method %||% "mnar",
      control_grp      = input$control_grp,
      species          = input$species,
      source           = src_of()
    ))

    # 非抛错版 prep (req 失败/预处理失败 -> NULL): 页签输出用它做前置判断,
    # 避免 renderUI 被 validation error 打断而显示成空白 (引导提示被吞掉)
    prep_ok <- reactive(tryCatch(prep(), error = function(e) NULL))

    prep <- reactive({
      raw <- raw_data(); req(raw)
      prm <- global_params()
      src <- prm$source %||% "diann"
      inf <- inferred()
      sn <- inf$snames; sc <- inf$sample_cols
      # 分组表: 结构不合法/空名/重名则忽略并退回自动推断 (与原版 app.R 判据一致)
      gm <- group_map()
      rename_col <- rename_disp <- NULL
      if (!is.null(gm)) {
        ok_gm <- is.data.frame(gm) && all(c("Sample", "Group") %in% colnames(gm)) &&
                 nrow(gm) == length(sn)
        if (ok_gm) {
          gm$Sample <- trimws(as.character(gm$Sample))
          gm$Group  <- trimws(as.character(gm$Group))
          ok_gm <- !any(!nzchar(gm$Sample)) && anyDuplicated(gm$Sample) == 0 &&
                   is.null(validate_group_map(gm))
        }
        if (!ok_gm) gm <- NULL
        else if (!identical(gm$Sample, sn)) {
          rename_col  <- stats::setNames(gm$Sample, sc)   # prep_run 按列名
          rename_disp <- stats::setNames(gm$Sample, sn)   # 批次表按显示名
        }
      }
      # 批次表: 校验同「生成并填入」; 样本改名后按显示名同步
      bm <- batch_map()
      if (!is.null(bm) && (!is.data.frame(bm) ||
                           !all(c("Sample", "Batch") %in% colnames(bm)) ||
                           !identical(as.character(bm$Sample), sn) ||
                           !is.null(validate_batch_map(bm, sn))))
        bm <- NULL
      if (!is.null(bm) && !is.null(rename_disp)) {
        hit <- match(as.character(bm$Sample), names(rename_disp))
        bm$Sample[!is.na(hit)] <- unname(rename_disp[hit[!is.na(hit)]])
      }
      out <- tryCatch(
        prep_run(raw, params = c(prm, list(use_combat = isTRUE(input$use_combat))),
                 sample_group_map = gm, sample_batch_map = bm, sample_rename = rename_col),
        error = function(e) {
          an_notify(paste("预处理失败:", conditionMessage(e)), "error", 10)
          NULL
        })
      if (!is.null(out) && !identical(prm$species, "auto") && !is.null(prm$species)) {
        sp <- switch(prm$species,
                     human = list(species = "Homo sapiens",      org_pkg = "org.Hs.eg.db", kegg_org = "hsa"),
                     mouse = list(species = "Mus musculus",      org_pkg = "org.Mm.eg.db", kegg_org = "mmu"),
                     rat   = list(species = "Rattus norvegicus", org_pkg = "org.Rn.eg.db", kegg_org = "rno"),
                     zebrafish = list(species = "Danio rerio",   org_pkg = "org.Dr.eg.db", kegg_org = "dre"))
        if (!is.null(sp)) {
          out$species  <- paste0(sp$species, "（手动指定）")
          out$org_pkg  <- sp$org_pkg
          out$kegg_org <- sp$kegg_org
          out$warnings <- setdiff(out$warnings,
                                  "未检测到明确物种标识，默认按 Human (org.Hs.eg.db) 注释")
        }
      }
      out
    })

    # ---------------- ② 预处理页输出 ----------------
    output$prep_page <- renderUI({
      if (!is.null(prep_ok())) return(NULL)
      div(class = "an-err", icon("circle-info"), " 请先在「① 数据与分组」读取矩阵。")
    })
    an_stat_card <- function(num, label)
      sprintf('<div class="an-stat-card"><div class="num">%s</div><div class="label">%s</div></div>',
              esc(num), esc(label))
    output$prep_stats <- renderUI({
      pp <- prep(); req(pp)
      HTML(paste0('<div class="an-stat-row">',
        an_stat_card(pp$n_before, "原始蛋白"),
        an_stat_card(pp$n_contam, "污染/反库剔除"),
        an_stat_card(pp$n_low, "低检出剔除"),
        an_stat_card(pp$n_final, "保留蛋白"),
        an_stat_card(sprintf("%.1f%%", pp$imp_pct),
                     if (pp$imputed) "插补占比" else "缺失占比"),
        an_stat_card(length(pp$snames), "样本数"),
        '</div>',
        '<div class="an-mono">',
        esc(sprintf("物种: %s | 插补: %s | 对照组: %s | 分组来源: %s",
                    pp$species, pp$impute_method, pp$control_grp, pp$map_src)),
        '</div>'))
    })
    output$prep_warnings <- renderUI({
      pp <- prep(); req(pp)
      if (!length(pp$warnings)) return(div(class = "an-ok", icon("circle-check"), " 无告警"))
      tags$ul(class = "an-warn-ul", lapply(pp$warnings, tags$li))
    })
    output$prep_missing <- renderUI({
      pp <- prep(); req(pp)
      mp <- tryCatch(missing_profile_plots(pp), error = function(e) NULL)
      if (is.null(mp))
        return(div(class = "an-err", "当前数据没有可用于绘图的定量值。"))
      tagList(
        div(class = "an-plot-box", figure_ui(mp$plots$A)),
        div(class = "an-plot-caption", "图 A：平均丰度 (log2) 与缺失率的关系"),
        div(class = "an-plot-box", figure_ui(mp$plots$B)),
        div(class = "an-plot-caption", "图 B：不同缺失率区间的丰度分布"))
    })
    output$prep_normbox <- renderUI({
      pp <- prep(); req(pp)
      div(class = "an-plot-box", figure_ui(median_norm_boxplot(pp)))
    })

    # ---------------- ③ QC ----------------
    mods <- reactive(input$modules %||% character(0))

    qc_res <- reactive({
      if (!"qc" %in% mods()) return(NULL)
      pp <- prep(); req(pp)
      dqc <- an_deps_check("qc")
      if (any(!dqc$installed)) return(NULL)
      qc_compute(pp, cor_min = input$cor_min, cv_bins = input$cv_bins)
    })
    output$qc_actions <- renderUI({
      q <- qc_res(); if (is.null(q)) return(NULL)
      div(style = "margin-bottom:10px;",
        downloadButton(ns("qc_zip"), "导出全部 QC 图 (zip)", class = "btn-sm btn-default",
                       icon = icon("file-zipper")),
        tags$span(class = "an-hint", sprintf("　共 %d 张图。", length(q$plots))))
    })
    output$qc_zip <- downloadHandler(
      filename = function() sprintf("QC_%s.zip", format(Sys.time(), "%Y%m%d_%H%M%S")),
      content = function(f) {
        q <- qc_res(); req(q)
        if (!requireNamespace("zip", quietly = TRUE)) stop("未安装 zip 包")
        d <- file.path(tempdir(), sprintf("qc_export_%s", format(Sys.time(), "%H%M%OS3")))
        dir.create(d, showWarnings = FALSE, recursive = TRUE)
        for (nm in names(q$plots))
          try(save_plot_obj(q$plots[[nm]], d, nm), silent = TRUE)
        files <- list.files(d, recursive = TRUE)
        if (length(files) == 0) stop("没有可导出的图形")
        old <- setwd(d); on.exit(setwd(old), add = TRUE)
        zip::zipr(f, files = files, mode = "mirror")
      })
    output$qc_figures <- renderUI({
      # 先判 prep 再调 qc_res: 矩阵未读时 qc_res 内部 req() 会抛验证错误,
      # 打断本输出的引导提示 (renderUI 的输出表现为空白页)
      if (is.null(prep_ok())) return(NULL)
      q <- qc_res()
      if (is.null(q)) {
        if (!"qc" %in% mods())
          return(div(class = "an-err", icon("circle-info"),
                     " 未执行 QC 模块：请在上方「分析模块」勾选「QC 可视化」。"))
        return(NULL)
      }
      tagList(lapply(names(q$plots), function(nm) {
        tagList(div(class = "an-plot-box", figure_ui(q$plots[[nm]])))
      }))
    })
    output$qc_stats <- renderUI({
      q <- qc_res(); req(q)
      s <- q$stats
      cv_min <- suppressWarnings(min(s$cv_median, na.rm = TRUE))
      cv_lab <- if (!is.finite(cv_min)) "—" else sprintf("%.1f%%", cv_min * 100)
      HTML(paste0('<div class="an-stat-row">',
        an_stat_card(sprintf("%.1f%%", s$pca_var[1]), "PC1 方差"),
        an_stat_card(sprintf("%.1f%%", s$pca_var[2]), "PC2 方差"),
        an_stat_card(sprintf("%.3f ~ %.3f", s$cor_range[1], s$cor_range[2]),
                     paste0("样本相关范围 (", s$cor_method, ")")),
        an_stat_card(cv_lab, "最低组内 CV 中位数"),
        '</div>'))
    })

    # ---------------- ④ 差异分析 ----------------
    de_res <- reactive({
      if (!"de" %in% mods()) return(NULL)
      pp <- prep(); req(pp)
      # 「不填补」时矩阵含 NA, limma 无法给出有效结果 -> 停用 (富集随之停用)
      if (!isTRUE(pp$imputed)) return(NULL)
      dde <- an_deps_check("de")
      if (any(!dde$installed)) return(NULL)
      de_compute(pp,
                 logFC_cutoff = input$de_logFC,
                 pval_cutoff = input$de_pval,
                 p_adjust_method = input$de_padj %||% "BH",
                 top_n_label = input$de_topn_label,
                 top_n_boxplot = input$de_topn_box,
                 heatmap_max = input$de_heatmap_max)
    })
    # 动态结果表 (每个对比一张)
    observe({
      dd <- de_res(); req(dd)
      if (!has_dt) return()
      for (k in seq_along(dd$pairs)) {
        local({
          kk <- k
          output[[paste0("de_tbl_", kk)]] <- DT::renderDT({
            DT::datatable(de_res()$pairs[[kk]]$res, rownames = FALSE,
                          options = list(scrollX = TRUE, pageLength = 10, dom = "tp"),
                          class = "compact stripe")
          })
        })
      }
    })
    an_fig_block <- function(p, caption) {
      if (is.null(p)) return(NULL)
      list(div(class = "an-plot-box", figure_ui(p)),
           div(class = "an-plot-caption", caption))
    }
    output$de_content <- renderUI({
      pp <- prep_ok()
      if (is.null(pp))
        return(div(class = "an-err", icon("circle-info"), " 请先在「① 数据与分组」读取矩阵。"))
      dd <- de_res()
      if (is.null(dd)) {
        why <- if (!"de" %in% mods()) "未勾选「limma 差异分析」模块。"
               else if (!isTRUE(pp$imputed))
                 "缺失值处理为「不填补」，差异分析已停用（请改选插补方法）。"
               else "依赖缺失 (见上方提示)。"
        return(div(class = "an-err", icon("circle-info"), why))
      }
      fig <- function(pt, stem, cap)
        an_fig_block(pt$plots[[stem]], sprintf("%s（%s）", cap, pt$contrast))
      an_dt <- function(output_id) if (has_dt) DT::DTOutput(output_id) else
        div(class = "an-err", "结果表需要 DT 包（install.packages(\"DT\")）。")
      if (identical(dd$mode, "single")) {
        pt <- dd$pairs[[1]]
        tagList(
          div(class = "an-ok", icon("circle-check"),
              sprintf(" %s：显著差异蛋白 %d 个（上调 %d / 下调 %d）",
                      pt$contrast, nrow(pt$sig), pt$sig_up, pt$sig_down)),
          fig(pt, "09_diff_volcano", "火山图"),
          fig(pt, "11_diff_count_barplot", "上下调数量统计"),
          fig(pt, "10_diff_heatmap", "差异蛋白 Z-score 热图"),
          fig(pt, "12_diff_top_protein_boxplot", "关键差异蛋白箱线图"),
          h4("结果表"), an_dt(ns("de_tbl_1")))
      } else {
        ptabs <- lapply(seq_along(dd$pairs), function(k) {
          pt <- dd$pairs[[k]]
          tabPanel(pt$contrast,
            div(class = "an-ok", icon("circle-check"),
                sprintf(" 显著差异蛋白 %d 个（上调 %d / 下调 %d）",
                        nrow(pt$sig), pt$sig_up, pt$sig_down)),
            fig(pt, "09_diff_volcano", "火山图"),
            fig(pt, "11_diff_count_barplot", "上下调数量统计"),
            fig(pt, "10_diff_heatmap", "差异蛋白 Z-score 热图"),
            fig(pt, "12_diff_top_protein_boxplot", "关键差异蛋白箱线图"),
            h4("结果表"), an_dt(ns(paste0("de_tbl_", k))))
        })
        anova_sec <- if (!is.null(dd$anova)) list(
          h4("全局 F 检验"),
          an_dt(ns("anova_tbl")),
          an_fig_block(dd$anova$plots[["10_multigroup_anova_heatmap"]],
                       "全局显著差异蛋白热图 (F 降序前 100)")) else NULL
        tagList(
          div(class = "an-ok", icon("circle-check"),
              sprintf(" %d 组：全局 F 检验显著 %s 个；两两对比 %d 组，显著并集 %d 个",
                      length(dd$pairs),
                      if (is.null(dd$anova)) "0" else nrow(dd$anova$sig),
                      length(dd$pairs), nrow(dd$sig))),
          anova_sec,
          do.call(tabsetPanel, ptabs))
      }
    })
    observe({
      dd <- de_res(); req(dd)
      if (!has_dt || is.null(dd$anova)) return()
      output$anova_tbl <- DT::renderDT({
        keep <- intersect(c("Protein.Group", "Genes", "F", "P.Value", "adj.P.Val",
                            "Significant"), colnames(dd$anova$res))
        DT::datatable(dd$anova$res[, keep, drop = FALSE], rownames = FALSE,
                      options = list(scrollX = TRUE, pageLength = 10, dom = "tp"),
                      class = "compact stripe")
      })
    })

    # ---------------- ⑤ 功能富集 ----------------
    enrich_res <- reactive({
      if (!"enrich" %in% mods()) return(NULL)
      pp <- prep(); dd <- de_res()
      req(pp, dd)
      den <- an_deps_check("enrich")
      if (any(!den$installed)) return(NULL)
      enrich_compute(pp, dd,
                     pval_cutoff = input$en_pval,
                     qval_cutoff = input$en_qval,
                     p_adjust_method = input$en_padj %||% "BH",
                     min_sig = input$en_minsig,
                     use_kegg = isTRUE(input$en_use_kegg),
                     kegg_online = identical(input$en_kegg, "online"))
    })
    output$enrich_content <- renderUI({
      pp <- prep()
      dd <- de_res()
      if (is.null(pp) || is.null(dd)) {
        if (is.null(prep())) return(NULL)
        why <- if (!"de" %in% mods())
          "「功能富集」依赖差异分析的显著蛋白结果，但「④ 差异分析」模块未勾选；请同时勾选两者。"
        else if (!isTRUE(prep()$imputed))
          "缺失值处理为「不填补」导致差异分析停用，功能富集随之不可用（请改选插补方法）。"
        else "差异分析依赖缺失（见 ④ 差异分析页提示）。"
        return(div(class = "an-err", icon("circle-info"), why))
      }
      # v1.14.1 修复: 此处引用了从未赋值的 en — 恰在预处理+DE 都成功 (富集最有意义的
      # 状态) 时必然抛 "object 'en' not found", 用户看到 Shiny 错误面板。补上赋值。
      en <- enrich_res()
      if (is.null(en))
        return(div(class = "an-err", icon("circle-info"),
                   if (!"enrich" %in% mods()) "未勾选「GO/KEGG 功能富集」模块。"
                   else "富集依赖缺失（见上方安装命令）。"))
      if (isTRUE(en$skipped))
        return(div(class = "an-err", icon("circle-info"), " 富集已跳过：", en$reason))
      go_figs <- en$plots[grepl("^13_enrichment_go_barplot_", names(en$plots))]
      an_dt <- function(output_id) if (has_dt) DT::DTOutput(output_id) else
        div(class = "an-err", "结果表需要 DT 包（install.packages(\"DT\")）。")
      tagList(
        div(class = "an-ok", icon("circle-check"),
            sprintf(" 显著条目 %d 条（来源: %s | KEGG: %s | 可映射背景基因 %d 个）",
                    if (is.null(en$tables$all)) 0 else nrow(en$tables$all),
                    paste(en$sources, collapse = ", "),
                    if (identical(en$kegg_source, "online")) "在线" else "本地",
                    en$n_bg)),
        lapply(names(go_figs), function(nm)
          an_fig_block(go_figs[[nm]], go_figs[[nm]]$label)),
        an_fig_block(en$plots[["14_enrichment_go_dotplot"]], "GO 富集气泡图 (各 ontology top 5)"),
        h4("GO 结果表"), an_dt(ns("go_tbl")),
        an_fig_block(en$plots[["15_enrichment_kegg_dotplot"]], "KEGG 通路富集气泡图"),
        h4("KEGG 结果表"), an_dt(ns("kegg_tbl")),
        if (length(en$warnings))
          tags$ul(class = "an-warn-ul", lapply(en$warnings, tags$li)))
    })
    observe({
      en <- enrich_res(); req(en)
      if (!has_dt || isTRUE(en$skipped)) return()
      output$go_tbl <- DT::renderDT({
        DT::datatable(en$tables$go %||% data.frame(), rownames = FALSE,
                      options = list(scrollX = TRUE, pageLength = 10, dom = "tp"),
                      class = "compact stripe")
      })
      output$kegg_tbl <- DT::renderDT({
        DT::datatable(en$tables$kegg %||% data.frame(), rownames = FALSE,
                      options = list(scrollX = TRUE, pageLength = 10, dom = "tp"),
                      class = "compact stripe")
      })
    })

    # ---------------- ⑥ 生成报告 ----------------
    shinyDirChoose(input, "report_dir_pick", roots = volumes)
    observeEvent(input$report_dir_pick, {
      p <- shinyFiles::parseDirPath(volumes, input$report_dir_pick)
      if (length(p)) updateTextInput(session, "report_dir", value = as.character(p))
    })
    report_root <- reactive({
      d <- trimws(input$report_dir %||% "")
      if (nzchar(d)) d else file.path(path.expand("~"), "diann_gui_analysis_reports")
    })
    output$report_dir_display <- renderText(paste0("报告将生成于: ", report_root()))

    report_state <- reactiveVal(NULL)

    # 全参数快照 (命名契约与 report_build 的 build_summary 对齐)
    params_all <- reactive(c(
      global_params(),
      list(file_name = if (!is.null(load_path())) basename(load_path()) else NA_character_,
           cor_min = input$cor_min, cv_bins = input$cv_bins,
           de_logFC_cutoff = input$de_logFC, de_pval_cutoff = input$de_pval,
           de_p_adjust_method = input$de_padj %||% "BH",
           de_top_n_label = input$de_topn_label, de_top_n_boxplot = input$de_topn_box,
           de_heatmap_max = input$de_heatmap_max,
           enrich_pval_cutoff = input$en_pval, enrich_qval_cutoff = input$en_qval,
           enrich_p_adjust_method = input$en_padj %||% "BH",
           enrich_min_sig = input$en_minsig, enrich_use_kegg = isTRUE(input$en_use_kegg),
           enrich_kegg_online = identical(input$en_kegg, "online"),
           enrich_ont = c("BP", "MF", "CC"), enrich_min_gssize = 3,
           enrich_max_gssize = 500, enrich_go_top_n = 10, enrich_kegg_top_n = 15),
      list(modules = mods())))

    output$report_ready <- renderUI({
      pp <- prep()
      if (is.null(pp))
        return(div(class = "an-err", icon("circle-info"), " 请先读取数据并完成预处理。"))
      div(class = "an-ok", icon("circle-check"),
          sprintf(" 数据就绪：%d 样本 / %d 组 / %d 个蛋白；已选模块：%s",
                  length(pp$snames), pp$n_groups, pp$n_final,
                  paste(c("预处理", mods()), collapse = "、")))
    })

    observeEvent(input$report_build, {
      pp <- prep(); req(pp)
      md <- mods()
      if (!length(md)) { an_notify("至少勾选一个分析模块 (QC / 差异 / 富集)。", "warning"); return() }
      root <- report_root()
      dir_err <- an_report_prepare_dir(root)
      if (!is.null(dir_err)) { an_notify(paste("报告目录不可用：", dir_err), "error", 12); return() }
      withProgress(message = "正在生成 HTML 报告…", value = 0.15, {
        res <- tryCatch({
          incProgress(0.25, detail = "输出图形与表格")
          out <- report_build(root, pp, qc_res(), de_res(), enrich_res(), params_all(), md)
          incProgress(0.35, detail = "打包 zip")
          zf <- file.path(root, paste0(basename(out$dir), ".zip"))
          err <- an_report_make_zip(out$dir, zf)
          out$zipfile <- if (is.null(err)) zf else NULL
          out$zip_err <- err
          out
        }, error = function(e) {
          an_notify(paste("报告生成失败:", conditionMessage(e)), "error", 12)
          NULL
        })
        report_state(res)
      })
      if (!is.null(report_state())) {
        if (is.null(report_state()$zipfile))
          an_notify(paste0("报告已生成，但打包 zip 失败：", report_state()$zip_err), "warning", 12)
        else an_notify("报告生成完成，可预览或下载 zip。", "message", 8)
      }
    })

    # 报告静态资源挂载 (会话级前缀, 避免多会话冲突)
    report_url_prefix <- paste0("an_report_", session$token)
    observe({
      s <- report_state(); req(s)
      suppressWarnings(try(removeResourcePath(report_url_prefix), silent = TRUE))
      addResourcePath(report_url_prefix, dirname(s$dir))
    })
    report_url <- function(s) {
      paste0(report_url_prefix, "/", utils::URLencode(basename(s$dir), reserved = TRUE),
             "/report.html")
    }

    output$report_actions <- renderUI({
      s <- report_state(); if (is.null(s)) return(NULL)
      has_zip <- !is.null(s$zipfile) && file.exists(s$zipfile)
      div(style = "margin-top:8px;",
        if (has_zip) downloadButton(ns("report_zip"), "下载报告 (zip)",
                                    class = "btn-success btn-sm", icon = icon("file-zipper")),
        tags$a(href = report_url(s), target = "_blank", class = "btn btn-sm btn-default",
               icon("up-right-from-square"), " 新窗口打开"))
    })
    output$report_zip <- downloadHandler(
      filename = function() paste0(basename(report_state()$dir %||% "analysis_report"), ".zip"),
      content = function(f) {
        s <- report_state(); req(s)
        if (is.null(s$zipfile) || !file.exists(s$zipfile)) return(invisible(NULL))
        if (!isTRUE(file.copy(s$zipfile, f, overwrite = TRUE)))
          stop("复制压缩包到下载临时文件失败")
        invisible(NULL)
      })
    output$report_result <- renderUI({
      s <- report_state(); if (is.null(s)) return(NULL)
      zip_ok <- !is.null(s$zipfile) && file.exists(s$zipfile)
      div(class = "an-card",
        h4("报告已生成"),
        div(class = "an-hint",
          sprintf("输出目录: %s ｜ %d 个图形、%d 个表格。", s$dir, s$n_figs, s$n_tables),
          if (zip_ok) sprintf("zip 压缩包 %.1f MB。", file.size(s$zipfile) / 1024^2) else ""),
        h4("报告预览"),
        tags$iframe(src = report_url(s), class = "an-report-preview"))
    })

    invisible(NULL)
  })
}
