# ============================================================
# server.R — 应用服务端逻辑
# ============================================================
app_server <- function(input, output, session) {
server <- function(input, output, session) {
  volumes <- cfg_get("BASE_VOLUMES")[file.exists(unname(cfg_get("BASE_VOLUMES")))]
  user <- Sys.getenv("USER"); if (!nzchar(user)) user <- Sys.info()[["user"]]

  # ---- 执行后端 (v1.12: Slurm 可选 / 本地单机) ----
  # UI 在启动时按同一解析结果条件渲染; 会话期间不切换后端。
  backend <- exec_backend()
  is_local <- identical(backend, "local")
  binfo <- backend_info()

  # 运行用户无权访问数据根目录时, 文件浏览器会静默显示为空 — 在此明确提示。
  # 不存在的卷 (如 e2e/演示用的合成根 /share/home/demo) 静默跳过:
  # 选择器本就按 file.exists 过滤, 这类卷是配置里的既定测试设施而非故障
  acc <- file.access(unname(cfg_get("BASE_VOLUMES")), 4)
  denied <- (is.na(acc) | acc != 0) & file.exists(unname(cfg_get("BASE_VOLUMES")))
  if (any(denied)) {
    showNotification(
      HTML(paste0(
        "<b>数据目录不可访问</b><br>当前 GUI 以用户 <b>", user, "</b> 运行, 无权读取 ",
        paste(sprintf("%s (%s)", names(cfg_get("BASE_VOLUMES"))[denied], unname(cfg_get("BASE_VOLUMES"))[denied]), collapse = ", "),
        "。<br>请检查该目录对当前用户的读权限 (属主/组/ACL), 或在配置中改指一个可读的数据根。"
      )),
      type = "error", duration = NULL
    )
  }

  # 本会话提交记录
  jobs <- reactiveValues(jobs = data.frame(
    jobid = character(), 任务名 = character(), 版本 = character(),
    输出目录 = character(), 提交时间 = character(), 邮箱 = character(),
    后端 = character(), stringsAsFactors = FALSE
  ))

  # 命令导入的文件路径覆盖层 (shinyFiles 选择器无法编程填充, 导入后按类勾选覆盖)
  ov <- reactiveValues(raws = character(0), raw_dir = "", fastas = character(0),
                       lib = "", ref = "", temp = "", out_dir = "")
  import_txt <- reactiveValues(txt = "尚未导入命令")

  # ---------- 文件选择器 ----------
  shinyFileChoose(input, "raw_files", roots = volumes, filetypes = c("raw", "mzML", "dia", "wiff"))
  shinyFileChoose(input, "lib_file", roots = volumes, filetypes = c("speclib", "parquet", "tsv", "msp", "sptxt"))
  shinyFileChoose(input, "ref_file", roots = volumes, filetypes = c("speclib", "parquet", "tsv", "msp", "sptxt"))
  shinyFileChoose(input, "fasta_file", roots = volumes, filetypes = c("fasta", "fa"))
  shinyFileChoose(input, "sif_pick", roots = volumes, filetypes = c("sif"))
  shinyDirChoose(input, "out_dir", roots = volumes)
  shinyDirChoose(input, "temp_dir", roots = volumes)
  shinyDirChoose(input, "raw_dir_btn", roots = volumes)
  shinyDirChoose(input, "log_dir_btn", roots = volumes)

  # sif 浏览选择 → 回填自定义路径输入框 (单一事实来源仍是 custom_sif, 手动修改不受影响)
  observeEvent(input$sif_pick, {
    fp <- tryCatch(parseFilePaths(volumes, input$sif_pick)$datapath, error = function(e) NULL)
    if (is.character(fp) && length(fp) == 1 && nzchar(fp)) {
      updateTextInput(session, "custom_sif", value = as.character(fp))
    }
  })

  # 当前生效镜像: 自定义路径 (勾选且非空) 优先, 否则下拉选择 —— 回显/验证/参数收集共用
  effective_sif <- reactive({
    if (isTRUE(input$use_custom_sif)) trimws(input$custom_sif %||% "")
    else as.character(input$sif_version %||% "")
  })

  # 本地作业状态文件告警 (v1.13: RDS/seq 损坏时一次性提示; 监控页 banner 托管)。
  # 损坏发生在后端深处的 local_jobs_load(), 告警写入 .cfg 后 UI 无从感知 —
  # 借监控页 10s 自动刷新轮询一次 (审查 P2: 静态 renderUI 告警可能晚到不显示)
  local_warn <- reactiveVal(cfg_get("LOCAL_JOBS_WARN") %||% "")
  observe({
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    w <- cfg_get("LOCAL_JOBS_WARN") %||% ""
    if (!identical(w, local_warn())) local_warn(w)
  })
  output$local_state_note <- renderUI({
    w <- local_warn()
    if (!nzchar(w)) return(NULL)
    tags$div(class = "alert alert-warning", style = "margin: 0 0 10px 0; padding: 8px 12px;",
             HTML(htmltools::htmlEscape(w)))
  })

  # ---------- SIF 版本识别 (v1.13: 版本只来自容器内实测, 结果懒缓存) ----------
  sif_rows <- reactiveVal(cfg_get("sif_df"))
  # 识别缓存落盘计数: sif_display/sif_version_info 借它获得 reactive 依赖 —
  # 否则深度验证写缓存后 (尤其 SIF_DIRS 外的自定义路径, sif_rows 合并结果不变),
  # ReactiveVal 去重不触发失效, 回显停留在"版本未识别" (审查 P1-C2)
  sif_probe_bump <- reactiveVal(0L)

  # 识别用 apptainer: 当前生效路径优先, 否则候选默认 (apptainer_default 已按 可执行+支持SIF 排序)
  sif_pick_apptainer <- function() {
    ap <- effective_apptainer()
    if (nzchar(ap)) ap else apptainer_default(apt_cands())
  }

  # 重建下拉选项 (保留仍有效的当前选择)
  sif_refresh_choices <- function() {
    merged <- sif_rows()
    .cfg$sif_df <- merged
    .cfg$sif_choices <- sif_choice_labels(merged)
    sel <- effective_sif()
    if (!nzchar(sel) || !sel %in% .cfg$sif_choices) {
      idx <- sif_default_index(merged, cfg_get("DEFAULT_SIF"))
      sel <- if (!is.na(idx)) merged$path[idx] else ""
    }
    updateSelectInput(session, "sif_version", choices = .cfg$sif_choices,
                      selected = if (nzchar(sel)) sel else NULL)
    invisible(NULL)
  }

  # 识别单个镜像并落缓存; 返回 sif_identify() 结果
  sif_identify_path <- function(path) {
    p <- trimws(as.character(path %||% ""))
    if (!nzchar(p)) return(list(ok = FALSE, version = "", stage = "", reason = "missing",
                                message = "未选择镜像", inspect = "", raw_version_lines = character(0)))
    res <- sif_identify(p, sif_pick_apptainer())
    fi <- file.info(p)
    probe <- sif_probe_load()
    probe <- sif_probe_record(probe, p, unname(fi$size), as.numeric(fi$mtime),
                              ver = res$version, ok = res$ok,
                              message = res$message, reason = res$reason)
    sif_probe_save(probe)
    sif_rows(sif_merge_probe(scan_sif_images(cfg_get("SIF_DIRS")), probe))
    sif_probe_bump(sif_probe_bump() + 1L)
    sif_refresh_choices()
    res
  }

  # 选中未识别镜像 → 自动识别; 有失败缓存不自动重试 (按钮可重试)。
  # ignoreInit = TRUE: 页面加载不触发识别 (兑现"启动不跑容器"承诺, 也避免首个会话
  # 同步阻塞); 用户切换下拉 / 点「识别所有未识别镜像」时才跑容器 (审查 P1-C3)。
  observeEvent(input$sif_version, ignoreInit = TRUE, {
    if (isTRUE(input$use_custom_sif)) return(invisible(NULL))
    p <- effective_sif()
    if (!nz_str(p)) return(invisible(NULL))
    r <- sif_rows()
    hit <- which(r$path == p)
    if (length(hit)) {
      if (isTRUE(r$verified[hit[1]])) return(invisible(NULL))
      if (nzchar(r$probe_message[hit[1]])) return(invisible(NULL))   # 上次失败: 等手动重试
    }
    res <- NULL
    withProgress(message = "识别镜像版本 (容器内运行 diann-linux)…", value = 0.4,
                 { res <- sif_identify_path(p) })
    if (isTRUE(res$ok)) {
      showNotification(sprintf("已识别: DIA-NN v%s (已缓存)", res$version), type = "message")
    }
  })

  observeEvent(input$sif_identify_all, {
    r <- sif_rows()
    todo <- r$path[!r$verified]
    if (!length(todo)) {
      showNotification("没有未识别的镜像", type = "message")
      return(invisible(NULL))
    }
    ok_n <- 0L; fails <- character(0)
    withProgress(message = sprintf("识别未识别镜像 0/%d…", length(todo)), value = 0, {
      for (i in seq_along(todo)) {
        incProgress(1 / length(todo), message = sprintf("识别未识别镜像 %d/%d…", i, length(todo)))
        res <- sif_identify_path(todo[i])
        if (isTRUE(res$ok)) ok_n <- ok_n + 1L
        else fails <- c(fails, sprintf("%s — %s", basename(todo[i]), substr(res$message, 1, 100)))
      }
    })
    if (length(fails)) {
      showNotification(HTML(htmltools::htmlEscape(
        sprintf("识别完成: 成功 %d / 失败 %d。失败明细:\n%s",
                ok_n, length(fails), paste(fails, collapse = "\n")))),
        type = "warning", duration = 20)
    } else {
      showNotification(sprintf("识别完成: 成功 %d / %d", ok_n, length(todo)), type = "message")
    }
  })

  output$sif_version_info <- renderUI({
    sif_probe_bump()   # 识别写缓存后立即重算 (P1-C2)
    p <- effective_sif()
    if (!nz_str(p)) return(NULL)
    r <- sif_rows()
    hit <- which(r$path == p)
    if (length(hit) && isTRUE(r$verified[hit[1]])) {
      tags$div(style = "color:#00a65a;font-weight:600;",
               sprintf("版本: v%s (已识别, 缓存)", r$ver[hit[1]]))
    } else if (length(hit) && nzchar(r$probe_message[hit[1]])) {
      tags$div(style = "color:#dd4b39;",
               sprintf("版本未识别 — 上次失败: %s (点「识别版本并深度验证」重试)",
                       substr(r$probe_message[hit[1]], 1, 120)))
    } else {
      v <- sif_version_of(p)
      if (nzchar(v)) {
        tags$div(style = "color:#00a65a;font-weight:600;", sprintf("版本: v%s (已识别, 缓存)", v))
      } else {
        tags$div(style = "color:#e08e0b;",
                 "版本未识别 — 选中后自动尝试; 也可点「识别版本并深度验证」")
      }
    }
  })

  selected_raws <- reactive({
    if (isTRUE(input$use_imported_raws) && length(ov$raws)) ov$raws
    else as.character(parseFilePaths(volumes, input$raw_files)$datapath)
  })
  selected_lib <- reactive({
    if (isTRUE(input$use_imported_lib) && nz_str(ov$lib)) ov$lib
    else as.character(parseFilePaths(volumes, input$lib_file)$datapath)
  })
  selected_ref <- reactive({
    if (isTRUE(input$use_imported_ref) && nz_str(ov$ref)) ov$ref
    else as.character(parseFilePaths(volumes, input$ref_file)$datapath)
  })
  selected_fasta <- reactive({
    if (isTRUE(input$use_imported_fasta) && length(ov$fastas)) ov$fastas
    else as.character(parseFilePaths(volumes, input$fasta_file)$datapath)
  })
  selected_out_dir <- reactive({
    if (isTRUE(input$use_imported_out) && nz_str(ov$out_dir)) ov$out_dir
    else as.character(parseDirPath(volumes, input$out_dir))
  })
  selected_temp_dir <- reactive({
    if (isTRUE(input$use_imported_temp) && nz_str(ov$temp)) ov$temp
    else as.character(parseDirPath(volumes, input$temp_dir))
  })
  selected_raw_dir <- reactive({
    if (isTRUE(input$use_imported_raw_dir) && nz_str(ov$raw_dir)) ov$raw_dir
    else as.character(parseDirPath(volumes, input$raw_dir_btn))
  })
  selected_log_dir <- reactive(as.character(parseDirPath(volumes, input$log_dir_btn)))

  # ---------- 路径回显 ----------
  output$sif_display <- renderText({
    sif_probe_bump()   # 识别写缓存后立即重算 (P1-C2)
    p <- effective_sif()
    if (!nz_str(p)) {
      if (isTRUE(input$use_custom_sif)) "(未填写自定义路径)" else "未找到可用镜像"
    } else {
      v <- sif_version_of(p)
      prefix <- if (isTRUE(input$use_custom_sif)) "(自定义" else "("
      sprintf("%sv%s) %s", prefix, if (nzchar(v)) v else "未识别", p)
    }
  })
  # ---------- apptainer 运行环境 (自动识别候选 → 下拉; 识别不到 → 手动路径) ----------
  apt_cands <- reactiveVal(cfg_get("APPTAINER_CANDS") %||% data.frame(
    path = character(0), kind = character(0), source = character(0), version = character(0),
    ok = logical(0), sif_ok = logical(0), checked_at = numeric(0), stringsAsFactors = FALSE))
  apptainer_info <- reactiveVal(NULL)

  # 当前生效 apptainer: 手动路径(勾选且非空) 优先, 否则下拉选择
  effective_apptainer <- reactive({
    v <- if (isTRUE(input$use_custom_apptainer)) trimws(input$custom_apptainer %||% "")
         else as.character(input$apptainer_version %||% "")
    if (!length(v)) "" else v[1]
  })

  # 某路径的运行时版本 + SIF 能力: 只读已探测结果 (候选缓存 / 「识别并验证」), 不跑子进程
  # (版本要求: apptainer ≥ 1.0 / singularity ≥ 3.0; 见 R/apptainer.R 的 SIF_MIN_MAJOR)
  apptainer_sif_state <- function(path) {
    p <- trimws(as.character(path %||% ""))
    out <- list(known = FALSE, sif_ok = NA, version = "", kind = "", note = "")
    if (!nzchar(p)) return(out)
    nkey <- function(x) suppressWarnings(normalizePath(path.expand(x), mustWork = FALSE))
    pk <- nkey(p)
    cands <- tryCatch(apptainer_cands_sif(apt_cands()), error = function(e) NULL)
    if (!is.null(cands) && nrow(cands)) {
      hit <- cands[vapply(cands$path, function(x) identical(nkey(x), pk), logical(1)), , drop = FALSE]
      if (nrow(hit)) {
        ok1 <- isTRUE(hit$ok[1])
        return(list(known = ok1,
                    sif_ok = if (ok1) hit$sif_ok[1] else NA,
                    version = if (ok1) as.character(hit$version[1]) else "",
                    kind = as.character(hit$kind[1]), note = ""))
      }
    }
    info <- apptainer_info()
    if (!is.null(info) && isTRUE(info$ok) && identical(nkey(info$path), pk)) {
      return(list(known = TRUE, sif_ok = info$sif_ok %||% NA,
                  version = as.character(info$version %||% ""),
                  kind = as.character(info$kind %||% ""),
                  note = as.character(info$sif_note %||% "")))
    }
    out
  }

  apply_apptainer_scan <- function(refresh = FALSE) {
    cands <- tryCatch(apptainer_candidates(refresh = refresh), error = function(e) NULL)
    if (is.null(cands)) return(invisible(NULL))
    .cfg$APPTAINER_CANDS <- cands
    .cfg$APPTAINER_CHOICES <- apptainer_choices(cands)
    apt_cands(cands)
    cur <- effective_apptainer()
    sel <- if (nzchar(cur) && cur %in% .cfg$APPTAINER_CHOICES) cur else apptainer_default(cands)
    updateSelectInput(session, "apptainer_version", choices = .cfg$APPTAINER_CHOICES, selected = sel)
    invisible(cands)
  }

  # 一个都没识别到: 直接展开"手动指定", 否则用户会卡在空下拉上
  session$onFlushed(function() {
    if (!length(cfg_get("APPTAINER_CHOICES"))) {
      updateCheckboxInput(session, "use_custom_apptainer", value = TRUE)
      showNotification("未自动识别到 apptainer/singularity: 请在「1. apptainer 运行环境」中手动指定路径",
                       type = "warning", duration = 12)
    }
  }, once = TRUE)

  observeEvent(input$refresh_apptainer, {
    withProgress(message = "正在扫描 apptainer…", value = 0.5, apply_apptainer_scan(refresh = TRUE))
    showNotification(sprintf("识别到 %d 个 apptainer/singularity 候选", nrow(apt_cands())), type = "message")
  })

  observeEvent(input$verify_apptainer, {
    apptainer_info(apptainer_check(effective_apptainer()))
  })

  output$apptainer_verify_result <- renderUI({
    info <- apptainer_info()
    if (is.null(info)) return(NULL)
    no_sif <- isTRUE(info$ok) && identical(info$sif_ok, FALSE)
    col <- if (no_sif) "#f39c12" else if (isTRUE(info$ok)) "#00a65a" else "#dd4b39"
    icon <- if (no_sif) "⚠" else if (isTRUE(info$ok)) "✓" else "✗"
    txt <- if (no_sif && nzchar(info$sif_note %||% "")) {
      sprintf("%s — %s", info$message, info$sif_note)
    } else info$message
    tags$div(style = sprintf("color:%s;font-size:13px;margin-top:4px;", col),
             HTML(sprintf("<b>%s</b> %s", icon, htmltools::htmlEscape(txt))))
  })

  output$apptainer_display <- renderText({
    p <- effective_apptainer()
    if (!nz_str(p)) return("未选择 (未自动识别到, 请手动指定路径)")
    if (isTRUE(input$use_custom_apptainer)) {
      info <- apptainer_info()
      if (!is.null(info) && identical(info$path, path.expand(trimws(p))) && isTRUE(info$ok)) {
        note <- if (identical(info$sif_ok, FALSE)) sprintf(" ⚠ 不支持 SIF (需 %s)", sif_min_version_text()) else ""
        return(sprintf("✓ %s%s (%s)", info$message, note, info$path))
      }
      return(sprintf("未验证 — %s (点击「识别并验证」)", p))
    }
    st <- apptainer_sif_state(p)
    ver <- if (isTRUE(st$known) && nzchar(st$version)) {
      sprintf("%s %s", if (nzchar(st$kind)) st$kind else "apptainer", st$version)
    } else "版本未知"
    note <- if (identical(st$sif_ok, FALSE)) sprintf(" ⚠ 不支持 SIF (需 %s)", sif_min_version_text()) else ""
    sprintf("%s%s (%s)", ver, note, p)
  })

  # ---------- 运行环境自检 (候选列表 + module 回退 + 运行身份) ----------
  output$apt_check_display <- renderUI({
    cands <- apt_cands()
    mod <- cfg_get("APPTAINER_MODULE") %||% NULL
    esc <- htmltools::htmlEscape
    fmt_line <- function(ok, txt, warn = FALSE) {
      col <- if (warn) "#f39c12" else if (ok) "#00a65a" else "#dd4b39"
      icon <- if (warn) "⚠ " else if (ok) "✓ " else "✗ "
      tags$div(style = "margin-bottom:2px;",
               tags$span(style = sprintf("color:%s;font-weight:bold;", col), icon),
               txt)
    }
    cur <- effective_apptainer()
    tagList(
      tags$div(style = "color:#666;font-size:12px;margin-bottom:4px;",
               HTML(sprintf("运行身份: <b>%s</b> · 配置: %s", esc(user),
                            esc(if (nzchar(cfg_get("CONFIG_FILE") %||% "")) cfg_get("CONFIG_FILE") else "(内置默认)")))),
      if (nrow(cands)) {
        cands <- apptainer_cands_sif(cands)
        tagList(lapply(seq_len(nrow(cands)), function(i) {
          ok <- isTRUE(cands$ok[i])
          # 能跑 --version 但读不了 SIF 的旧版本 (singularity 2.x): 黄灯 + 明确版本要求
          no_sif <- ok && identical(cands$sif_ok[i], FALSE)
          note <- if (no_sif) {
            sprintf(" <b style='color:#dd4b39'>⚠ 不支持 SIF</b> <small>需 %s</small>",
                    esc(sif_min_version_text()))
          } else ""
          fmt_line(ok, HTML(sprintf("%s <b>%s</b> <small>(%s)</small>%s%s<br><code style='word-break:break-all'>%s</code>",
                       esc(cands$kind[i]),
                       esc(if (ok) cands$version[i] else "版本未知"),
                       esc(cands$source[i]),
                       note,
                       if (identical(cands$path[i], cur)) " <b>← 当前选中</b>" else "",
                       esc(cands$path[i]))),
                   warn = no_sif)
        }))
      } else {
        fmt_line(FALSE, HTML("未找到 apptainer/singularity<br><small>请手动指定路径, 或在 config.R 配置 APPTAINER_PATHS</small>"))
      },
      if (!is.null(mod)) fmt_line(isTRUE(mod$ok), HTML(sprintf(
        "module 回退 <code>%s</code> %s<small>%s</small>", esc(cfg_get("APPTAINER_MODULE_FALLBACK")),
        if (isTRUE(mod$ok)) "可用 " else "不可用 ",
        if (isTRUE(mod$ok) && nzchar(mod$path)) sprintf("(%s)", esc(mod$path)) else ""))),
      tags$div(style = "color:#777;font-size:12px;margin-top:4px;",
               sprintf("状态目录: %s", esc(dirname(cfg_get("NOTIFY_STATE")))))
    )
  })

  # ---------- 镜像可用性验证 ----------
  # 快速验证 = 本地静态检查 (<1s); 深度验证 = apptainer inspect + 容器内启动 (最长 45s)。
  # 单进程 Shiny 中后者会阻塞所有会话, 因此拆成两个按钮、收紧超时, 并默认只跑快速检查。
  sif_verify <- reactiveVal(NULL)
  sif_verify_run <- function(deep = FALSE) {
    sif <- effective_sif()
    rows <- list()
    add_row <- function(kind, text) {
      col <- switch(kind, ok = "#00a65a", bad = "#dd4b39", warn = "#f39c12", info = "#3c8dbc")
      icon <- switch(kind, ok = "✓", bad = "✗", warn = "⚠", info = "ℹ")
      rows[[length(rows) + 1]] <<- tags$div(
        style = sprintf("color:%s;margin:1px 0;", col),
        HTML(sprintf("<b>%s</b> %s", icon, htmltools::htmlEscape(text))))
    }
    if (!nz_str(sif)) { add_row("bad", "未选择镜像"); return(rows) }
    lc <- sif_check_local(sif)
    if (!lc$exists) { add_row("bad", sprintf("镜像不存在: %s", sif)); return(rows) }
    size_mb <- lc$size_bytes / 1024^2
    if (is.na(size_mb)) add_row("warn", sprintf("文件存在但无法读取大小: %s", sif))
    else if (size_mb < 1) add_row("warn", sprintf("文件仅 %.2f MB, 可疑 (正常 DIA-NN 镜像为数百 MB)", size_mb))
    else add_row("ok", sprintf("文件存在, %.0f MB", size_mb))
    if (!isTRUE(lc$readable)) {
      add_row("bad", sprintf("GUI 运行身份 (%s) 无权读取该镜像, 作业将无法启动容器",
                             Sys.info()[["user"]]))
      return(rows)
    }
    add_row("ok", "GUI 运行身份可读取")
    if (!isTRUE(lc$sif_magic)) {
      add_row("bad", "SIF 魔数校验失败 — 文件不是有效的 SIF 镜像 (可能损坏或下载截断)")
      return(rows)
    }
    add_row("ok", "SIF 镜像格式有效")
    ap <- effective_apptainer()
    if (!nz_str(ap) || !file.exists(ap) || file.access(ap, 1) != 0) {
      add_row("info", "未选择在 GUI 节点可用的 apptainer, 跳过容器级检查 (作业脚本内自行回退查找)")
      return(rows)
    }
    add_row("ok", sprintf("apptainer 可用: %s", ap))
    # 版本下限: SIF 需要 apptainer ≥ 1.0 / singularity ≥ 3.0。2.x 的 --version 一切正常,
    # 但 inspect/exec 在解析镜像头时就失败 —— 必须在这里给结论, 不能让用户只看到裸报错。
    st <- apptainer_sif_state(ap)
    if (!isTRUE(st$known)) {
      info <- tryCatch(suppressWarnings(apptainer_check(ap)), error = function(e) NULL)
      if (!is.null(info)) {
        st <- list(known = isTRUE(info$ok), sif_ok = info$sif_ok %||% NA,
                   version = as.character(info$version %||% ""),
                   kind = as.character(info$kind %||% ""),
                   note = as.character(info$sif_note %||% ""))
      }
    }
    ver_txt <- if (nzchar(st$version)) sprintf("%s %s", if (nzchar(st$kind)) st$kind else "apptainer", st$version) else ""
    if (identical(st$sif_ok, FALSE)) {
      add_row("bad", sprintf("%s 不支持 SIF 镜像 (需要 %s): %s",
                             if (nzchar(ver_txt)) ver_txt else ap, sif_min_version_text(), sif_2x_symptom()))
      add_row("info", "请改选 apptainer ≥ 1.0 / singularity ≥ 3.0 的路径; 该路径已被写入作业脚本时, 作业同样会在启动容器时失败")
      return(rows)
    }
    if (isTRUE(st$sif_ok) && nzchar(ver_txt)) {
      add_row("ok", sprintf("运行时版本满足 SIF 要求: %s (需 %s)", ver_txt, sif_min_version_text()))
    }
    if (!isTRUE(deep)) {
      add_row("info", "快速验证通过; 需要确认容器内能启动 diann-linux 请点「识别版本并深度验证」")
      return(rows)
    }
    ins <- tryCatch(suppressWarnings(apptainer_run(ap, c("inspect", shQuote(sif)), timeout = 15)),
                    error = function(e) paste("探测出错:", conditionMessage(e)))
    ins_txt <- if (is.character(ins)) paste(ins, collapse = "\n") else ""
    if (grepl("org.label-schema", ins_txt)) {
      from <- sub(".*org.label-schema.usage.singularity.deffile.from:[[:space:]]*([^\n]+).*", "\\1", ins_txt)
      lbl <- if (from != ins_txt && nzchar(from)) sprintf(" (镜像来源: %s)", trimws(from)) else ""
      add_row("ok", sprintf("apptainer inspect 通过%s", lbl))
    } else {
      tl <- tail(ins_txt[nzchar(ins_txt)], 1)
      if (!length(tl)) tl <- "(无输出)"
      # 2.x 的 stderr 带 ANSI 颜色码和 \r 拼接 (如 "\033[91mERROR : ... \033[31mABORT : ..."), 原样显示很乱
      tl <- gsub("\r", " ", gsub("\033\\[[0-9;]*[A-Za-z]", "", tl))
      add_row("bad", sprintf("apptainer inspect 失败: %s", substr(trimws(tl), 1, 200)))
      if (grepl("Unknown image format", ins_txt, fixed = TRUE)) {
        add_row("info", sprintf("该报错说明运行时读不了 SIF 镜像头: 需要 %s", sif_min_version_text()))
      }
      return(rows)
    }
    incProgress(0.4, detail = "容器内启动 diann-linux…")
    # --version 非 DIA-NN 已知旗标, 但二进制仍会先打印版本横幅; 正则从合并输出提取, 不依赖具体流
    exe <- tryCatch(suppressWarnings(apptainer_run(ap, c("exec", shQuote(sif), "diann-linux", "--version"), timeout = 30)),
                    error = function(e) paste("探测出错:", conditionMessage(e)))
    exe_txt <- if (is.character(exe)) paste(exe, collapse = "\n") else ""
    # 用 perl 正则: 非 perl 引擎下字符类里的 \n 是字面量"反斜杠+n"(会误排除字母 n)
    m <- regmatches(exe_txt, regexpr("DIA-NN [0-9][^,(\\n]*", exe_txt, perl = TRUE))
    if (length(m)) {
      ver_real <- trimws(sub("^DIA-NN ", "", m))
      ver_num <- sub("^([0-9]+(?:\\.[0-9]+)*).*", "\\1", ver_real, perl = TRUE)
      add_row("ok", sprintf("容器内 DIA-NN 可执行, 实际版本: %s", ver_real))
      # v1.13: 深度验证解析到版本 → 写入识别缓存 (下拉/回显/提交记账共用)
      try({
        fi <- file.info(sif)
        probe <- sif_probe_load()
        probe <- sif_probe_record(probe, sif, unname(fi$size), as.numeric(fi$mtime),
                                  ver = ver_num, ok = TRUE,
                                  message = sprintf("容器内 DIA-NN 可执行, 实际版本: %s", ver_real))
        sif_probe_save(probe)
        sif_rows(sif_merge_probe(scan_sif_images(cfg_get("SIF_DIRS")), probe))
        sif_probe_bump(sif_probe_bump() + 1L)
        sif_refresh_choices()
      }, silent = TRUE)
    } else {
      add_row("warn", "容器内启动 diann-linux 未成功 — 若为 GUI 节点限制 (FUSE/命名空间) 可忽略, 以作业实际运行为准")
    }
    rows
  }
  observeEvent(input$verify_sif, {
    sif_verify(tags$div(style = "margin-top:4px;font-size:13px;", sif_verify_run(FALSE)))
  })
  observeEvent(input$verify_sif_deep, {
    withProgress(message = "深度验证镜像 (最长约 45 秒)…", value = 0.2, {
      rows <- sif_verify_run(TRUE)
      sif_verify(tags$div(style = "margin-top:4px;font-size:13px;", rows))
    })
  })
  output$sif_verify_result <- renderUI(sif_verify())
  output$raw_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_raws) && length(ov$raws)) "(导入) " else ""
    if (length(selected_raws())) paste0(mk, paste(selected_raws(), collapse = "\n")) else "未选 RAW 文件"
  })
  output$raw_dir_display <- renderText({
    mk <- if (isTRUE(input$use_imported_raw_dir) && nz_str(ov$raw_dir)) "(导入) " else ""
    if (length(selected_raw_dir())) paste0(mk, selected_raw_dir()) else "未选目录"
  })
  output$lib_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_lib) && nz_str(ov$lib)) "(导入) " else ""
    if (length(selected_lib())) paste0(mk, selected_lib()) else "未选光谱库"
  })
  output$ref_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_ref) && nz_str(ov$ref)) "(导入) " else ""
    if (length(selected_ref())) paste0(mk, selected_ref()) else "未选校准库"
  })
  output$fasta_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_fasta) && length(ov$fastas)) "(导入) " else ""
    if (length(selected_fasta())) paste0(mk, paste(selected_fasta(), collapse = "\n")) else "未选 FASTA"
  })
  output$out_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_out) && nz_str(ov$out_dir)) "(导入) " else ""
    if (length(selected_out_dir())) paste0(mk, selected_out_dir()) else "未选输出目录"
  })
  output$temp_path_display <- renderText({
    mk <- if (isTRUE(input$use_imported_temp) && nz_str(ov$temp)) "(导入) " else ""
    if (length(selected_temp_dir())) paste0(mk, selected_temp_dir()) else "未选临时目录 (使用默认)"
  })
  output$log_dir_display <- renderText({
    if (length(selected_log_dir())) selected_log_dir() else "未指定 (自动定位: 手动目录 → 本会话提交记录 → GUI 注册表 → scontrol → sacct 工作目录)"
  })

  # ---------- 参数收集 ----------
  params_ready <- reactive({
    out_dir <- if (length(selected_out_dir())) selected_out_dir() else ""
    rep_name <- trimws(input$report_name)
    sif <- effective_sif()
    time_h <- input$time_h
    # 不再把 <1 h 转 NA: 0.5 h 会变成"不限时"(共享集群资源安全问题)。时限在脚本里按分钟取整。
    list(
      job_name = trimws(input$job_name %||% ""),
      partition = if (identical(backend, "slurm")) (input$partition %||% "compute") else NA_character_,
      threads = input$threads %||% 16, mem_gb = input$mem_gb %||% 64, time_h = time_h,
      sif = sif,
      apptainer_bin = effective_apptainer(),
      ver = if (nz_str(sif)) {
        r <- sif_rows(); h <- which(r$path == sif)
        v <- if (length(h) && isTRUE(r$verified[h[1]])) as.character(r$ver[h[1]]) else sif_version_of(sif)
        if (nzchar(v)) v else "未识别"
      } else "",
      raw_mode = input$raw_mode,
      raws = selected_raws(), raw_dir = if (length(selected_raw_dir())) selected_raw_dir() else "",
      lib = if (length(selected_lib())) selected_lib() else "",
      ref = if (length(selected_ref())) selected_ref() else "",
      fastas = selected_fasta(),
      temp = if (length(selected_temp_dir())) selected_temp_dir() else "",
      out_dir = out_dir,
      report_name = rep_name,
      out_file = if (nz_str(out_dir) && nz_str(rep_name)) file.path(out_dir, paste0(rep_name, ".tsv")) else "",
      # Slurm 脚本头专用占位符 (%j 由 sbatch 展开); 本地模式脚本不使用这两个字段
      slurm_out = if (identical(backend, "slurm") && nz_str(out_dir)) file.path(out_dir, "slurm-%j.out") else "",
      slurm_err = if (identical(backend, "slurm") && nz_str(out_dir)) file.path(out_dir, "slurm-%j.err") else "",
      verbose = as.integer(input$verbose %||% 1), qvalue = input$qvalue %||% 0.01,
      reanalyse = input$mbr, rt_prof = input$rt_prof, peptidoforms = input$peptidoforms,
      proteoforms = input$proteoforms, matrices = input$matrices,
      indiv_reports = input$indiv_reports, unimod4 = input$unimod4,
      mass_acc = input$mass_acc, mass_acc_ms1 = input$mass_acc_ms1, window = input$window,
      min_peak = input$min_peak, rt_window = input$rt_window, im_window = input$im_window,
      quant_qvalue = input$quant_qvalue, protein_quant_qvalue = input$protein_quant_qvalue,
      matrix_qvalue = input$matrix_qvalue,
      var_mods_max = input$var_mods_max,
      var_mod_rows = lapply(1:6, function(i) c(
        trimws(input[[paste0("vm_name_", i)]]),
        trimws(input[[paste0("vm_mass_", i)]]),
        trimws(input[[paste0("vm_sites_", i)]])
      )),
      fixed_mod_rows = lapply(1:3, function(i) c(
        trimws(input[[paste0("fm_name_", i)]]),
        trimws(input[[paste0("fm_mass_", i)]]),
        trimws(input[[paste0("fm_sites_", i)]])
      )),
      met_excision = input$met_excision, reannotate = input$reannotate,
      use_cut = input$use_cut %||% FALSE, cut = trimws(input$cut %||% ""),
      missed_cleavages = input$missed_cleavages,
      min_pep_len = input$min_pep_len, max_pep_len = input$max_pep_len,
      min_pr_mz = input$min_pr_mz, max_pr_mz = input$max_pr_mz,
      min_pr_charge = input$min_pr_charge, max_pr_charge = input$max_pr_charge,
      min_fr_mz = input$min_fr_mz, max_fr_mz = input$max_fr_mz,
      predictor = input$predictor, light_models = input$light_models,
      gen_spec_lib = input$gen_spec_lib,
      out_lib = trimws(input$out_lib %||% ""), out_lib_qvalue = input$out_lib_qvalue,
      export_quant = input$export_quant, report_decoys = input$report_decoys,
      individual_windows = input$individual_windows, individual_mass_acc = input$individual_mass_acc,
      global_norm = input$global_norm, no_rt_norm = input$no_rt_norm, no_prot_norm = input$no_prot_norm,
      high_acc = input$high_acc, no_skyline = input$no_skyline, no_stats = input$no_stats,
      xic = input$xic, min_corr = input$min_corr,
      fasta_search = input$fasta_search %||% FALSE,
      convert_only = input$convert_only %||% FALSE,
      cont_exclude = input$cont_exclude %||% FALSE,
      cont_tag = trimws(input$cont_tag %||% "cRAP-"),
      extra = input$extra_args %||% "",
      notify_email = trimws(input$notify_email %||% ""),
      project_desc = trimws(input$project_desc %||% "")
    )
  })

  # ---------- 校验 ----------
  validation_msgs <- reactive({
    p <- params_ready()
    msgs <- character(0)
    warn <- character(0)
    info <- character(0)
    if (!nz_str(p$sif)) msgs <- c(msgs, "✗ 未选择 sif 镜像")
    else if (!file.exists(p$sif)) msgs <- c(msgs, sprintf("✗ sif 镜像不存在: %s", p$sif))
    else {
      # 本地静态校验 (瞬时, 无 system2); 深度验证 (apptainer inspect/容器内启动) 用版本页「验证镜像可用性」按钮
      lc <- sif_check_local(p$sif)
      if (!isTRUE(lc$readable)) {
        msgs <- c(msgs, sprintf("✗ GUI 运行身份 (%s) 无权读取该镜像, 作业将无法启动容器: %s",
                                Sys.info()[["user"]], p$sif))
      } else if (!isTRUE(lc$sif_magic)) {
        msgs <- c(msgs, "✗ 该文件不是有效的 SIF 镜像 (魔数校验失败, 可能损坏或下载截断); 可用版本页「验证镜像可用性」按钮逐项排查")
      } else if (!is.na(lc$size_bytes) && lc$size_bytes < 1024^2) {
        warn <- c(warn, sprintf("⚠ 镜像仅 %.2f MB, 可疑 (正常 DIA-NN 镜像为数百 MB)", lc$size_bytes / 1024^2))
      }
      # v1.13: 版本识别状态 (不阻断 — Slurm 计算节点可能可跑容器而 GUI 节点不能)
      r <- sif_rows(); h <- which(r$path == p$sif)
      known <- if (length(h)) isTRUE(r$verified[h[1]]) else nzchar(sif_version_of(p$sif))
      if (known) {
        info <- c(info, "ℹ 镜像版本已识别 (容器内实测)")
      } else if (length(h) && nzchar(r$probe_message[h[1]])) {
        warn <- c(warn, sprintf("⚠ 镜像版本识别失败: %s (可在「2. DIA-NN 版本」点「识别版本并深度验证」重试)",
                                substr(r$probe_message[h[1]], 1, 100)))
      } else {
        info <- c(info, "ℹ 镜像版本未识别 (不影响提交; 选中镜像后会自动识别)")
      }
      if (identical(backend, "local")) {
        info <- c(info, "ℹ 本地模式要求 GUI 所在主机可运行 apptainer/singularity (作业在本机执行)")
      }
    }
    # apptainer 运行环境: 空选择阻断; "GUI 节点看不见/不可执行"只警告 (strict 模式才阻断)。
    # 不在每次按键时跑 --version (子进程卡顿); 深度校验由「识别并验证」按钮或提交前触发。
    apt <- trimws(p$apptainer_bin %||% "")
    if (!nzchar(apt)) {
      msgs <- c(msgs, "✗ 未选择 apptainer 运行环境 (未自动识别到, 请手动指定路径)")
    } else if (!startsWith(path.expand(apt), "/")) {
      msgs <- c(msgs, "✗ apptainer 路径必须是服务器绝对路径 (以 / 开头)")
    } else {
      ap_abs <- path.expand(apt)
      info_hit <- apptainer_info()
      verified <- !is.null(info_hit) && identical(info_hit$path, ap_abs) && isTRUE(info_hit$ok)
      if (!verified) {
        local_msg <- if (!file.exists(ap_abs)) {
          sprintf("⚠ GUI 节点看不到该 apptainer: %s (若为计算节点专用安装可继续; 作业会按回退链查找)", ap_abs)
        } else if (file.access(ap_abs, 1) != 0) {
          sprintf("⚠ apptainer 不可执行: %s", ap_abs)
        } else NULL
        if (!is.null(local_msg)) {
          if (isTRUE(cfg_get("APPTAINER_STRICT_CHECK"))) {
            msgs <- c(msgs, sub("^⚠", "✗", local_msg))
          } else {
            warn <- c(warn, local_msg)
          }
        }
      }
      # 版本下限: 2.x 无法读 SIF, 这是必然而非"节点差异", 一律阻断 (不看 strict)
      st <- apptainer_sif_state(ap_abs)
      if (identical(st$sif_ok, FALSE)) {
        msgs <- c(msgs, sprintf(
          "✗ 所选 %s %s 不支持 SIF 镜像 (需要 %s): %s",
          if (nzchar(st$kind)) st$kind else "apptainer", st$version,
          sif_min_version_text(), sif_2x_symptom()))
      }
      if (grepl("singularity", basename(ap_abs), fixed = TRUE)) {
        info <- c(info, sprintf("ℹ 当前使用 singularity 命令 (与 apptainer 等价; SIF 需 singularity ≥ %d.0)",
                                SIF_MIN_MAJOR[["singularity"]]))
      }
    }
    th <- suppressWarnings(as.integer(p$threads))
    if (length(p$threads) != 1 || is.na(th) || th < 1 || th > 1024) {
      msgs <- c(msgs, "✗ 线程数无效 (需 1–1024 的整数): Slurm --cpus-per-task 与 DIA-NN --threads 均使用该值")
    }
    jn <- trimws(p$job_name %||% "")
    if (!nzchar(jn)) {
      msgs <- c(msgs, "✗ 任务名不能为空")
    } else if (grepl("[/\\\\\r\n\t]", jn)) {
      msgs <- c(msgs, "✗ 任务名不能包含 / \\ 或换行/制表符 (会破坏脚本文件名)")
    } else if (nchar(jn, type = "chars") > 64L) {
      msgs <- c(msgs, "✗ 任务名长度不能超过 64 个字符")
    }
    if (!is.null(input$time_h) && length(input$time_h) == 1 && !is.na(input$time_h)) {
      mins <- ceiling(60 * input$time_h)
      if (mins < 1) msgs <- c(msgs, "✗ 时限至少 1 分钟")
      else info <- c(info, if (is_local) {
        sprintf("ℹ 时限按 %d 分钟执行 (本地模式到点由运行器终止)", mins)
      } else {
        sprintf("ℹ 时限按 %d 分钟提交 (Slurm -t %d)", mins, mins)
      })
    }
    has_raws <- length(p$raws) > 0 || nz_str(p$raw_dir)
    # 预测库独立生成模式 (--gen-spec-lib) 不需要 RAW 文件
    if (!has_raws && !isTRUE(p$gen_spec_lib)) msgs <- c(msgs, "✗ 未选择 RAW 文件/目录")
    if (!nz_str(p$out_dir)) msgs <- c(msgs, "✗ 未选择输出目录")
    else if (dir.exists(p$out_dir) && file.access(p$out_dir, 2) != 0) {
      msgs <- c(msgs, sprintf(paste0("✗ 输出目录对 GUI 运行身份 (%s) 不可写, 将无法保存脚本/结果: %s",
                                     " — 请改用输出工作区目录 (如 project/), 或请目录属主为 GUI 账户授权 (setfacl -m u:%s:rwx 或 chgrp+2770)"),
                              Sys.info()[["user"]], p$out_dir, Sys.info()[["user"]]))
    }
    if (nz_str(p$notify_email)) {
      # perl=TRUE 必需: POSIX TRE 引擎不识别字符类内的 \s, 会把 [^@,\s] 当作排除字母 s, 含 s 的邮箱被误判
      if (grepl("^[^@,\\s]+@[^@,\\s]+\\.[^@,\\s]+(\\s*,\\s*[^@,\\s]+@[^@,\\s]+\\.[^@,\\s]+)*$", p$notify_email, perl = TRUE)) {
        if (!file.exists(cfg_get("MAIL_CONF"))) {
          warn <- c(warn, sprintf("ℹ 已填写邮箱, 但未找到邮件配置 %s, 将不会发送通知邮件 (参考 mail_config.example.txt)", cfg_get("MAIL_CONF")))
        }
      } else {
        msgs <- c(msgs, "✗ 邮箱通知格式不正确 (多个邮箱用英文逗号分隔)")
      }
    }
    if (isTRUE(p$convert_only)) {
      warn <- c(warn, "ℹ 转换模式: 命令仅包含文件与 --convert, .dia 文件将保存在 RAW 文件所在目录")
    } else {
      if (!nz_str(p$out_file)) msgs <- c(msgs, "✗ 主报告文件名不能为空")
      else if (grepl("[/\\\\\r\n\t]", p$report_name)) msgs <- c(msgs, "✗ 主报告文件名不能包含 / \\ 或换行")
      if (nz_str(p$lib)) {
        # 光谱库模式: FASTA 可选 (注释/重注释), 无需 --fasta-search
      } else if (!length(p$fastas)) {
        msgs <- c(msgs, "✗ 光谱库与 FASTA 至少需提供一个")
      } else if (!isTRUE(p$fasta_search) && !isTRUE(p$gen_spec_lib)) {
        msgs <- c(msgs, "✗ 无光谱库时必须勾选 --fasta-search (无库搜索) 或 --gen-spec-lib (生成预测库)")
      }
    }
    # --gen-spec-lib 双语义: 无光谱库 = FASTA 预测建库; 有光谱库 = 经验谱库工作流 (搜库+精修输出库, DIA-NN 推荐做法, 不告警)
    if (isTRUE(p$gen_spec_lib)) {
      if (!length(p$fastas) && !nz_str(p$lib)) {
        msgs <- c(msgs, "✗ 生成预测库必须提供 FASTA (或选择光谱库以生成经验谱库)")
      } else if (has_raws && !nz_str(p$lib)) {
        warn <- c(warn, "ℹ FASTA 预测建库与搜库将同场执行 (组合模式); DIA-NN 建议先不选 RAW 独立生成预测库, 再用该库搜库 (库可复用, 结果更稳)")
      } else if (has_raws) {
        info <- c(info, "ℹ 经验谱库工作流: 以光谱库搜库, 并用本次鉴定精修输出谱库 (--out-lib); 该库可用于全部样本的后续搜索")
      }
    }
    if (isTRUE(p$cont_exclude) && isTRUE(p$gen_spec_lib)) {
      info <- c(info, "ℹ 污染物 cRAP 将编入输出谱库, 便于后续搜库时鉴定并经 --cont-quant-exclude 从定量矩阵扣除")
    }
    if (nz_str(p$lib) && length(p$fastas)) {
      info <- c(info, "ℹ 已同时选择光谱库与 FASTA: FASTA 预测前体将并入搜索空间 (可扩充库覆盖; 若 FASTA 与库内容相同则为重复预测, 清除 FASTA 可提速)")
    }
    if (isTRUE(p$cont_exclude) && nz_str(cfg_get("CON_FASTA")) && !file.exists(cfg_get("CON_FASTA"))) {
      msgs <- c(msgs, sprintf("✗ 污染物 FASTA 不存在: %s", cfg_get("CON_FASTA")))
    }
    for (m in p$var_mod_rows) {
      if (any(nz_str(m)) && !all(nz_str(m))) msgs <- c(msgs, sprintf("✗ 可变修饰行不完整: %s (需 名称,质量,位点)", paste(m, collapse = ",")))
    }
    for (m in p$fixed_mod_rows) {
      if (any(nz_str(m)) && !all(nz_str(m))) msgs <- c(msgs, sprintf("✗ 固定修饰行不完整: %s", paste(m, collapse = ",")))
    }
    # 可变修饰行数 > --var-mods: 超出部分不会被搜索 (v1.9 事故邻域)
    n_var <- sum(vapply(p$var_mod_rows, function(m) all(nz_str(m)), logical(1)))
    vmax <- suppressWarnings(as.integer(p$var_mods_max))
    if (!is.na(vmax) && n_var > vmax) {
      warn <- c(warn, sprintf("⚠ 可变修饰填了 %d 行, 但每肽段最大可变修饰数为 %d: 超出部分不会进入搜索空间 (建议调到 ≥%d)",
                              n_var, vmax, n_var))
    }
    # 容器可见性: apptainer 默认只绑 $HOME / 当前目录 / /tmp, 其它路径必须写进 BIND_PATHS
    if (!isTRUE(p$convert_only)) {
      roots <- c(Sys.getenv("HOME"), getwd(), cfg_get("BIND_PATHS") %||% character(0))
      inputs <- c(p$raws, p$raw_dir, p$lib, p$ref, p$fastas, p$temp, p$out_dir)
      hidden <- container_visible(inputs, roots)
      if (length(hidden)) {
        warn <- c(warn, sprintf(paste0("⚠ 以下路径不在 $HOME / 当前目录 / BIND_PATHS 内, 容器里可能看不到 ",
                                       "(历史 v1.4 事故类别; 如属共享盘请加入 config.R 的 BIND_PATHS): %s"),
                                paste(unique(hidden), collapse = ", ")))
      }
    }
    if (nz_str(p$out_lib)) {
      if (!isTRUE(p$gen_spec_lib)) {
        info <- c(info, "ℹ 未勾选「生成谱图库」, --out-lib 不会写入命令 (填写值已忽略)")
      } else if (!startsWith(p$out_lib, "/")) {
        msgs <- c(msgs, "✗ 谱库输出路径必须是服务器绝对路径 (以 / 开头)")
      } else if (!dir.exists(dirname(p$out_lib))) {
        msgs <- c(msgs, sprintf("✗ 谱库输出路径的父目录不存在: %s", dirname(p$out_lib)))
      }
    }
    if (nz_str(p$out_lib) && grepl("^[A-Za-z]:[\\\\/]", p$out_lib)) {
      msgs <- c(msgs, "✗ --out-lib 是 Windows 盘符路径 (如 I:\\...), 服务器上不可用, 请清空或改为服务器路径")
    }
    # 额外参数中的裸旗标 (手输或历史残留) 会让 diann-linux 直接报错
    toks <- strsplit(trimws(p$extra), "[[:space:]]+")[[1]]
    toks <- toks[nzchar(toks)]
    vflags <- PATH_VALUE_FLAGS
    bare <- character(0)
    if (length(toks)) for (i in seq_along(toks)) {
      if (toks[i] %in% vflags && (i == length(toks) || grepl("^--", toks[i + 1]))) bare <- c(bare, toks[i])
    }
    if (length(bare)) msgs <- c(msgs, sprintf(
      "✗ 额外参数中 %s 缺少取值 (通常是命令导入时 Windows 路径被丢弃残留), 请清理「额外参数」",
      paste(unique(bare), collapse = " ")))
    # ---- 本地模式专属校验 (v1.12) ----
    # 单机没有调度器: 运行时必须在本机可用; 资源限制只能建议——内存不可强制,
    # 时限由 local_runner.sh 的 timeout 强制。这里统一给出清晰的阻断/警告。
    if (is_local) {
      slot <- tryCatch(local_next_slot_info(), error = function(e)
        list(n = 0L, eta = NA_real_, earliest_job = "", unknown_limit = FALSE,
             detail = "无法读取本地作业状态"))
      nrun <- slot$n
      mx <- suppressWarnings(as.integer(cfg_get("LOCAL_MAX_JOBS") %||% 0L))
      if (!is.na(mx) && mx > 0 && nrun >= mx) {
        tail_txt <- if (isTRUE(slot$unknown_limit)) "请等作业完成或手动取消"
                    else "此后可提交 (提前完成可提前提交)"
        msgs <- c(msgs, sprintf("✗ 本地并发已达上限 LOCAL_MAX_JOBS=%d (%s); %s",
                                mx, slot$detail, tail_txt))
      } else if (nrun > 0) {
        extra <- if (isTRUE(slot$unknown_limit)) "" else sprintf("; %s", slot$detail)
        info <- c(info, sprintf("ℹ 当前已有 %d 个本地作业在运行; 单机同时跑多个 DIA-NN 会争抢 CPU/内存%s",
                                nrun, extra))
      }
      th <- suppressWarnings(as.integer(p$threads))
      ncpu <- tryCatch(local_cpu_count(), error = function(e) NA_integer_)
      if (!is.na(th) && !is.na(ncpu) && th > ncpu) {
        warn <- c(warn, sprintf("⚠ 线程数 %d 超过本机 CPU 核数 %d; 本地模式没有排队机制, 可能拖慢整机", th, ncpu))
      }
      if (isTRUE(cfg_get("LOCAL_MEM_ADVISORY")) && !is.null(p$mem_gb) &&
          length(p$mem_gb) == 1 && !is.na(p$mem_gb)) {
        mem_free <- tryCatch(local_mem_available_gb(), error = function(e) NA_real_)
        if (!is.na(mem_free) && p$mem_gb > mem_free) {
          warn <- c(warn, sprintf("⚠ 申请内存 %.0f GB 超过本机当前可用 %.1f GB; 本地模式只做建议检查, 不会强制限制",
                                  p$mem_gb, mem_free))
        }
      }
    }
    list(block = msgs, warn = warn, info = info)
  })

  output$validation_msgs <- renderUI({
    v <- validation_msgs()
    tags$div(
      if (length(v$block)) tags$p(class = "msg-err", HTML(paste(v$block, collapse = "<br>"))),
      if (length(v$warn)) tags$p(style = "color:#b8860b;", HTML(paste(v$warn, collapse = "<br>"))),
      if (length(v$info)) tags$p(style = "color:#5a7ca6;", HTML(paste(v$info, collapse = "<br>"))),
      if (!length(v$block) && !length(v$warn) && !length(v$info)) tags$p(style = "color:#27ae60;", "✔ 校验通过, 可提交")
    )
  })

  # ---------- 预览 ----------
  output$preview <- renderText({
    # v1.12: 预览与提交共用同一脚本生成逻辑 (Slurm 头 / 本地脚本)
    backend_script(params_ready(), backend)
  })

  # ---------- 预设模板 ----------
  observeEvent(input$preset_lib, {
    updateCheckboxInput(session, "convert_only", value = FALSE)
    updateCheckboxInput(session, "fasta_search", value = TRUE)
    updateCheckboxInput(session, "gen_spec_lib", value = TRUE)
    updateCheckboxInput(session, "predictor", value = TRUE)
    showNotification("已应用预测库模板: 请选择 FASTA 与输出目录; --out-lib 留空时自动存为 <输出目录>/library.speclib (生成 library.predicted.speclib)",
                     type = "message", duration = 12)
  })
  observeEvent(input$preset_convert, {
    updateCheckboxInput(session, "convert_only", value = TRUE)
    showNotification("已切换为 RAW→DIA 转换模式: 只需选择 RAW 文件与输出目录, 其余分析参数将被忽略",
                     type = "message", duration = 12)
  })

  # ---------- 命令导入 ----------
  # 导入前的分析参数重置 (限定范围): 清掉上一次导入/手填的残留, 保证导入结果只反映粘贴的命令。
  # 不动: sif 镜像、Slurm 分区/内存/时限、邮箱、项目简介; raw_mode 仅在导入实际
  # 提供 RAW 文件/目录时按导入内容切换 (否则会静默沿用上一次的选择)。
  # threads 兼具资源属性, 采取 sticky 策略——仅当导入命令含 --threads 时才改写。
  reset_import_state <- function() {
    for (ctrl in unname(BOOL_FLAG_MAP)) updateCheckboxInput(session, ctrl, value = FALSE)
    for (ctrl in c("use_cut", "cont_exclude")) updateCheckboxInput(session, ctrl, value = FALSE)
    for (ctrl in c("qvalue", "mass_acc", "mass_acc_ms1", "window", "min_peak", "rt_window",
                   "im_window", "quant_qvalue", "protein_quant_qvalue", "matrix_qvalue",
                   "missed_cleavages", "min_pep_len", "max_pep_len", "min_pr_mz", "max_pr_mz",
                   "min_pr_charge", "max_pr_charge", "min_fr_mz", "max_fr_mz",
                   "out_lib_qvalue", "xic", "min_corr")) {
      updateNumericInput(session, ctrl, value = NA)
    }
    updateSelectInput(session, "verbose", selected = "1")
    updateTextInput(session, "cut", value = "K*,R*,!*P")
    updateTextInput(session, "out_lib", value = "")
    updateTextInput(session, "cont_tag", value = "cRAP-")
    updateTextInput(session, "report_name", value = "report")
    updateTextAreaInput(session, "extra_args", value = "")
    for (i in 1:6) {
      updateTextInput(session, paste0("vm_name_", i), value = vm_default(i, 1))
      updateTextInput(session, paste0("vm_mass_", i), value = if (i <= 2) vm_default(i, 2) else "")
      updateTextInput(session, paste0("vm_sites_", i), value = if (i <= 2) vm_default(i, 3) else "")
    }
    for (i in 1:3) {
      updateTextInput(session, paste0("fm_name_", i), value = "")
      updateTextInput(session, paste0("fm_mass_", i), value = "")
      updateTextInput(session, paste0("fm_sites_", i), value = "")
    }
    updateNumericInput(session, "var_mods_max", value = 1)
    ov$raws <- character(0); ov$raw_dir <- ""; ov$fastas <- character(0)
    ov$lib <- ""; ov$ref <- ""; ov$temp <- ""; ov$out_dir <- ""
    for (ctrl in c("use_imported_raws", "use_imported_raw_dir", "use_imported_lib",
                   "use_imported_fasta", "use_imported_ref", "use_imported_out",
                   "use_imported_temp")) {
      updateCheckboxInput(session, ctrl, value = FALSE)
    }
  }

  observeEvent(input$import_btn, {
    txt <- input$import_cmd
    if (!nz_str(txt)) {
      showNotification("请先在文本框中粘贴 DIA-NN 命令", type = "error")
      return()
    }
    pr <- parse_diann_command(txt)
    reset_import_state()

    for (flag in pr$bool) updateCheckboxInput(session, unname(BOOL_FLAG_MAP[[flag]]), value = TRUE)
    for (flag in names(pr$num)) {
      if (flag == "--verbose") {
        updateSelectInput(session, "verbose", selected = as.character(as.integer(pr$num[[flag]])))
      } else {
        updateNumericInput(session, unname(NUM_FLAG_MAP[[flag]]), value = pr$num[[flag]])
      }
    }
    if (!is.null(pr$text[["--cut"]])) {
      updateTextInput(session, "cut", value = pr$text[["--cut"]])
      updateCheckboxInput(session, "use_cut", value = TRUE)
    }
    ol <- pr$text[["--out-lib"]]
    if (!is.null(ol) && !is_win_path(ol)) updateTextInput(session, "out_lib", value = ol)
    if (!is.null(pr$text[["--cont-quant-exclude"]])) {
      updateTextInput(session, "cont_tag", value = pr$text[["--cont-quant-exclude"]])
      updateCheckboxInput(session, "cont_exclude", value = TRUE)
    }
    if (isTRUE(pr$cont_fasta)) updateCheckboxInput(session, "cont_exclude", value = TRUE)

    if (length(pr$var_mods)) {
      for (i in seq_len(min(length(pr$var_mods), 6))) {
        updateTextInput(session, paste0("vm_name_", i), value = pr$var_mods[[i]][1])
        updateTextInput(session, paste0("vm_mass_", i), value = pr$var_mods[[i]][2])
        updateTextInput(session, paste0("vm_sites_", i), value = pr$var_mods[[i]][3])
      }
    }
    # var_mods_max: 显式 --var-mods 优先, 修饰行数仅兜底; 不回读 input (shiny 批量更新下读到的是旧值)
    vmm <- imported_var_mods_max(pr)
    if (!is.null(vmm)) updateNumericInput(session, "var_mods_max", value = vmm)
    if (length(pr$fixed_mods)) {
      for (i in seq_len(min(length(pr$fixed_mods), 3))) {
        updateTextInput(session, paste0("fm_name_", i), value = pr$fixed_mods[[i]][1])
        updateTextInput(session, paste0("fm_mass_", i), value = pr$fixed_mods[[i]][2])
        updateTextInput(session, paste0("fm_sites_", i), value = pr$fixed_mods[[i]][3])
      }
    }

    # 文件路径写入覆盖层 (shinyFiles 无法编程填充); 超出 cfg_get("BASE_VOLUMES") 范围的路径拒绝导入
    f <- pr$files
    rejected <- character(0)
    scope_keep <- function(x, label) {
      if (!length(x) || (length(x) == 1 && !nzchar(x))) return(x)
      ok <- path_in_scope(x)
      bad <- x[!ok]
      if (length(bad)) rejected <<- c(rejected, sprintf("  %s: %s", label, paste(bad, collapse = ", ")))
      if (length(x) == 1) (if (ok) x else "") else x[ok]
    }
    f$raws <- scope_keep(f$raws, "RAW")
    f$raw_dir <- scope_keep(f$raw_dir, "RAW 目录")
    f$fastas <- scope_keep(f$fastas, "FASTA")
    f$lib <- scope_keep(f$lib, "光谱库")
    f$ref <- scope_keep(f$ref, "校准库")
    f$temp <- scope_keep(f$temp, "临时目录")
    f$out_dir <- scope_keep(f$out_dir, "输出目录")
    if (length(f$raws) || nz_str(f$raw_dir) || length(f$fastas) || nz_str(f$lib) ||
        nz_str(f$ref) || nz_str(f$temp) || nz_str(f$out_dir)) {
      ov$raws <- f$raws; ov$raw_dir <- f$raw_dir; ov$fastas <- f$fastas
      ov$lib <- f$lib; ov$ref <- f$ref; ov$temp <- f$temp; ov$out_dir <- f$out_dir
      # 按类自动勾选覆盖 (该类解析出路径才勾)
      if (length(f$raws))    updateCheckboxInput(session, "use_imported_raws", value = TRUE)
      if (nz_str(f$raw_dir)) updateCheckboxInput(session, "use_imported_raw_dir", value = TRUE)
      if (length(f$fastas))  updateCheckboxInput(session, "use_imported_fasta", value = TRUE)
      if (nz_str(f$lib))     updateCheckboxInput(session, "use_imported_lib", value = TRUE)
      if (nz_str(f$ref))     updateCheckboxInput(session, "use_imported_ref", value = TRUE)
      if (nz_str(f$out_dir)) updateCheckboxInput(session, "use_imported_out", value = TRUE)
      if (nz_str(f$temp))    updateCheckboxInput(session, "use_imported_temp", value = TRUE)
      # RAW 输入方式随导入内容切换, 否则 dir 模式会忽略导入的 --f、files 模式会忽略 --dir-all
      if (nz_str(f$raw_dir) && !length(f$raws)) updateRadioButtons(session, "raw_mode", selected = "dir")
      if (length(f$raws) && !nz_str(f$raw_dir)) updateRadioButtons(session, "raw_mode", selected = "files")
    }
    if (nz_str(pr$report_name)) updateTextInput(session, "report_name", value = pr$report_name)

    if (length(pr$unknown)) {
      updateTextAreaInput(session, "extra_args",
                          value = trimws(paste(pr$unknown, collapse = " ")))
    }

    info <- c(sprintf("✔ 已重置旧分析参数并填充: %d 个布尔旗标 | %d 个数值参数 | %d 行可变修饰 | %d 行固定修饰",
                      length(pr$bool), length(pr$num), length(pr$var_mods), length(pr$fixed_mods)))
    if (length(pr$var_mods) > 6) info <- c(info, sprintf("⚠ 可变修饰超过 6 行, 仅导入前 6 行 (丢弃 %d 行)", length(pr$var_mods) - 6L))
    if (length(pr$fixed_mods) > 3) info <- c(info, sprintf("⚠ 固定修饰超过 3 行, 仅导入前 3 行 (丢弃 %d 行)", length(pr$fixed_mods) - 3L))
    if (length(pr$bool)) info <- c(info, paste0("布尔旗标: ", paste(pr$bool, collapse = " ")))
    if (length(pr$num)) info <- c(info, paste0("数值: ", paste(sprintf("%s = %s", names(pr$num), unlist(pr$num)), collapse = "; ")))
    if (length(f$raws)) info <- c(info, sprintf("RAW 文件 ×%d (已写入导入覆盖层)", length(f$raws)))
    if (nz_str(f$raw_dir)) info <- c(info, paste0("RAW 目录 (--dir/--dir-all): ", f$raw_dir))
    if (length(f$fastas)) info <- c(info, sprintf("FASTA ×%d (已写入导入覆盖层)", length(f$fastas)))
    if (nz_str(f$lib)) info <- c(info, paste0("光谱库: ", f$lib))
    if (nz_str(f$out_dir)) info <- c(info, paste0("输出目录: ", f$out_dir))
    if (length(rejected)) info <- c(info,
      c(sprintf("⚠ 以下路径超出允许的数据范围 (%s), 已拒绝导入:",
                paste(unname(cfg_get("BASE_VOLUMES")), collapse = ", ")), rejected))
    if (isTRUE(pr$cont_fasta)) info <- c(info, "检测到内置污染物库 --fasta, 已自动转换为启用污染物扣除")
    if (length(pr$windows_paths)) info <- c(info, c("⚠ 以下为 Windows 路径, 服务器上不可用, 已跳过:", paste0("  ", pr$windows_paths)))
    if (isTRUE(pr$bare_lib) && "--gen-spec-lib" %in% pr$bool) {
      info <- c(info, "检测到裸 --lib 且命令无 RAW 文件 (Windows 预测库生成命令): 已自动勾选「生成谱图库」, 谱库默认存为 <输出目录>/library.speclib")
      others <- setdiff(pr$bare, "--lib")
      if (length(others)) info <- c(info, sprintf("以下无取值旗标已忽略: %s", paste(others, collapse = " ")))
    } else if (length(pr$bare)) {
      info <- c(info, sprintf("以下旗标无取值 (Windows GUI 路径留空时导出), 已忽略: %s", paste(pr$bare, collapse = " ")))
    }
    if (length(pr$unknown)) info <- c(info, c("以下未知旗标已追加到「额外参数」:", paste0("  ", pr$unknown)))
    import_txt$txt <- paste(info, collapse = "\n")
    showNotification("命令解析完成, 参数已填充", type = "message", duration = 6)
  })
  output$import_result <- renderText(import_txt$txt)

  # ---------- 集群节点资源 ----------
  sinfo_df <- reactive({
    if (!identical(backend, "slurm")) return(NULL)  # 本地模式无集群节点表 (UI 也不渲染)
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    out <- tryCatch(
      suppressWarnings(system("sinfo -N -h --states=all -o '%N|%P|%C|%t|%m|%e|%O'", intern = TRUE)),
      error = function(e) character(0))
    if (!length(out)) return(NULL)
    rows <- lapply(out, function(l) {
      f <- strsplit(l, "|", fixed = TRUE)[[1]]
      if (length(f) < 7) return(NULL)
      cpu <- strsplit(f[3], "/", fixed = TRUE)[[1]]
      cpu_str <- if (length(cpu) >= 4) sprintf("%s / %s / %s", cpu[1], cpu[2], cpu[4]) else f[3]
      data.frame(节点 = f[1], 分区 = f[2], `CPU(分配/空闲/总)` = cpu_str, 状态 = f[4],
                 `总内存(GB)` = round(suppressWarnings(as.numeric(f[5])) / 1024, 1),
                 `空闲内存(GB)` = round(suppressWarnings(as.numeric(f[6])) / 1024, 1),
                 CPU负载 = suppressWarnings(as.numeric(f[7])),
                 stringsAsFactors = FALSE, check.names = FALSE)
    })
    rows <- Filter(Negate(is.null), rows)
    if (!length(rows)) NULL else do.call(rbind, rows)
  })
  output$sinfo_table <- renderTable({
    d <- sinfo_df()
    if (is.null(d)) {
      data.frame(信息 = if (is_local) "本地模式: 无 Slurm 集群节点资源表"
                        else "(sinfo 无输出——无法获取集群节点信息)", stringsAsFactors = FALSE)
    } else d
  }, striped = TRUE, bordered = TRUE, na = "-")

  # ---------- 提交 ----------
  observeEvent(input$submit_job, {
    # v1.12: 整体 tryCatch —— 任何后端提交错误都转成通知, 绝不让 Shiny 会话断连。
    # (v1.11 实测: 无 Slurm 时 system2("sbatch") 抛错 -> 浏览器永久断连且无失败提示)
    tryCatch({
      v <- validation_msgs()
      if (length(v$block)) {
        showNotification(HTML(paste(v$block, collapse = "<br>")), type = "error", duration = NULL)
        return()
      }
      p <- params_ready()
      # 提交前 apptainer 校验: Slurm 模式保留原有"手动路径才验证/strict 才阻断"策略;
      # 本地模式在本机执行, 运行时必须真正可用 -> 一律真实校验并阻断。
      need_verify <- isTRUE(input$use_custom_apptainer) || is_local
      if (need_verify) {
        info <- apptainer_check(p$apptainer_bin)
        apptainer_info(info)
        # 版本下限: 2.x 读不了 SIF, 提交后必然在容器启动阶段失败 -> 直接阻断 (不受 strict 影响)
        if (isTRUE(info$ok) && identical(info$sif_ok, FALSE)) {
          msg <- sprintf("%s %s 不支持 SIF 镜像 (需要 %s): %s",
                         info$kind, info$version, sif_min_version_text(), sif_2x_symptom())
          showNotification(HTML(paste0("✗ 已阻止提交: ", htmltools::htmlEscape(msg))),
                           type = "error", duration = NULL)
          return()
        }
        if (!isTRUE(info$ok)) {
          msg <- sprintf("apptainer 未能验证: %s", info$message)
          if (is_local || isTRUE(cfg_get("APPTAINER_STRICT_CHECK"))) {
            showNotification(HTML(paste0("✗ 本地模式在本机执行, ", htmltools::htmlEscape(msg),
                                         " — 请先在「1. apptainer 运行环境」识别并验证一个可用的运行时")),
                             type = "error", duration = NULL)
            return()
          }
          showNotification(paste("提示:", msg, "— 作业将按回退链查找 apptainer"),
                           type = "warning", duration = 8)
        }
      }
      script_dir <- file.path(p$out_dir, "diann_gui_scripts")
      if (!dir.create(script_dir, recursive = TRUE, showWarnings = FALSE) && !dir.exists(script_dir)) {
        showNotification(paste("无法创建脚本目录:", script_dir,
                               "(GUI 运行身份对输出目录无写权限 — 请改用输出工作区目录, 或请目录属主为该身份授权)"),
                         type = "error", duration = NULL)
        return()
      }
      # 遗留产物归档: 旧 report/矩阵改名为 *.pre_<时间戳>.tsv, 防止其掩盖本次运行的状态判定
      archived <- archive_stale_artifacts(p$out_dir, p$out_file)
      # 保留策略: 清理过期脚本/rc/项目简介/旧归档 (默认 90 天), 防止输出目录无限增长
      cleaned <- try(cleanup_old_artifacts(p$out_dir, cfg_get("RETENTION_DAYS")), silent = TRUE)
      if (!is.numeric(cleaned)) cleaned <- 0L
      job_name <- safe_job_name(p$job_name)
      sh_path <- file.path(script_dir, sprintf("diann_%s_%s.sh", format(Sys.time(), "%Y%m%d_%H%M%S"), job_name))
      desc_path <- if (nz_str(p$project_desc)) sub("\\.sh$", "_desc.txt", sh_path) else ""
      if (nz_str(desc_path)) writeLines(p$project_desc, desc_path)
      pp <- p; pp$script_path <- sh_path; pp$desc_file <- desc_path; pp$job_name <- job_name
      # 预览/提交共用同一份脚本生成逻辑: Slurm 头 + 共享 body, 或本地脚本 (无 #SBATCH)
      writeLines(backend_script(pp, backend), sh_path)
      res <- backend_submit(pp, sh_path, backend = backend)
      if (!isTRUE(res$ok)) {
        msg <- if (length(res$message) && nzchar(res$message)) res$message else "未知错误"
        showNotification(HTML(paste0("✗ 提交失败:<br>", htmltools::htmlEscape(msg))),
                         type = "error", duration = NULL)
        return()
      }
      jid <- as.character(res$job_id)
      backend_cn <- if (is_local) "本地" else "Slurm"
      jobs$jobs <- rbind(jobs$jobs, data.frame(
        jobid = jid, 任务名 = job_name, 版本 = p$ver,
        输出目录 = p$out_dir, 提交时间 = format(Sys.time(), "%H:%M:%S"),
        邮箱 = if (nz_str(p$notify_email)) p$notify_email else "",
        后端 = backend_cn, stringsAsFactors = FALSE
      ))
      updateNumericInput(session, "log_id", value = suppressWarnings(as.integer(jid)))
      try(jobs_registry_add(jid, job_name, p$out_dir, script_path = sh_path,
                            out_file = p$out_file, sif = p$sif,
                            apptainer = p$apptainer_bin %||% NA_character_,
                            ver = p$ver, backend = backend, pid = res$pid,
                            log = res$log_out), silent = TRUE)
      if (nz_str(p$notify_email)) {
        try(diann_notify_add(list(jobid = jid, to = p$notify_email, task = job_name,
                                  out_dir = p$out_dir, out_file = p$out_file, sif = p$sif,
                                  script_path = sh_path, desc_file = desc_path,
                                  backend = backend, log_out = res$log_out)), silent = TRUE)
        try(ensure_diann_watcher(), silent = TRUE)
      }
      showNotification(sprintf("✔ 提交成功, %s JobID: %s\n脚本: %s", backend_cn, jid, sh_path),
                       type = "message", duration = 10)
      if (nrow(archived)) {
        showNotification(HTML(paste0("已归档上次运行的遗留产物 (防掩盖本次状态):<br>",
                                     paste(htmltools::htmlEscape(sprintf("%s → %s", archived$from, archived$to)),
                                           collapse = "<br>"))),
                         type = "warning", duration = 12)
      }
      if (is.numeric(cleaned) && cleaned > 0L) {
        showNotification(sprintf("按保留策略清理了 %d 个过期脚本/归档产物 (RETENTION_DAYS=%s)",
                                 cleaned, cfg_get("RETENTION_DAYS")),
                         type = "message", duration = 8)
      }
    }, error = function(e) {
      showNotification(HTML(paste0("✗ 提交异常: ", htmltools::htmlEscape(conditionMessage(e)))),
                       type = "error", duration = NULL)
    })
  })

  # ---------- 任务队列 ----------
  # 快照按当前执行后端生成 (Slurm: squeue/sacct 20s 缓存; 本地: 本地作业状态文件),
  # 供队列表/历史表/通知面板共用。
  output$squeue_output <- renderText({
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    snap <- tryCatch(backend_snapshot(backend, refresh = TRUE), error = function(e) NULL)
    out <- if (is.null(snap)) character(0) else snap$lines
    if (!length(out)) {
      if (is_local) "(本地队列空闲)" else "(squeue 无输出)"
    } else paste(out, collapse = "\n")
  })
  # sacct 状态码 → 中文 (20.11 的 CANCELLED 可能带 "by <uid>" 尾巴, 用前缀匹配)
  sacct_state_cn <- function(s) {
    map <- c(COMPLETED = "已完成", RUNNING = "运行中", PENDING = "排队中", COMPLETING = "收尾中",
             CONFIGURING = "配置中", FAILED = "失败", TIMEOUT = "超时", OUT_OF_MEMORY = "内存超限",
             NODE_FAIL = "节点故障", PREEMPTED = "被抢占", SUSPENDED = "挂起", BOOT_FAIL = "启动失败",
             DEADLINE = "到期终止", REQUEUED = "重新排队", CANCELLED = "已取消")
    out <- character(length(s))
    for (i in seq_along(s)) {
      x <- toupper(trimws(s[i]))
      if (!nzchar(x)) { out[i] <- x; next }
      hit <- names(map)[x == names(map)]
      if (!length(hit)) {
        pfx <- names(map)[startsWith(x, names(map))]
        if (length(pfx)) hit <- pfx[which.max(nchar(pfx))]
      }
      out[i] <- if (length(hit)) unname(map[hit[1]]) else s[i]
    }
    out
  }
  output$sacct_table <- renderTable({
    if (isTRUE(input$auto_refresh)) invalidateLater(10000)
    input$refresh_q
    # v1.12: 历史表来源由后端决定 (Slurm: sacct; 本地: 本地作业状态文件)
    d <- tryCatch(backend_history(backend), error = function(e) NULL)
    if (is.null(d) || !nrow(d)) {
      msg <- if (is_local) {
        "(暂无已完成的本地作业)"
      } else {
        "(sacct 无输出——本集群未开启作业记账 (accounting), 无法显示历史)"
      }
      return(data.frame(信息 = msg, stringsAsFactors = FALSE))
    }
    d$状态 <- sacct_state_cn(d$状态)
    d$运行时长[!nzchar(d$运行时长) | grepl("^Unknown$", d$运行时长, ignore.case = TRUE)] <- "-"
    d$结束时间[!nzchar(d$结束时间) | grepl("^Unknown$", d$结束时间, ignore.case = TRUE)] <- "-"
    d
  }, striped = TRUE, bordered = TRUE, na = "-")
  output$jobs_table <- renderTable(jobs$jobs, striped = TRUE, bordered = TRUE)
  output$notify_status <- renderText({
    if (isTRUE(input$auto_refresh)) invalidateLater(15000)
    try(ensure_diann_watcher(), silent = TRUE)  # 页面打开期间 watcher 失联的自愈
    state <- diann_notify_load()
    recs <- state$recs
    if (!length(recs)) return("")
    lines <- c("—— 提交记录与邮件通知 (最近 100 条) ——")
    live_budget <- 5L  # 未处理记录的实时状态合成上限 (共用快照/本地状态文件)
    # 记录可能混合旧 slurm 与 v1.12 local, 状态函数/日志路径按记录后端懒加载
    fns_cache <- list()
    get_fns <- function(bk) {
      bk <- as.character(bk)[1]
      if (is.null(fns_cache[[bk]])) {
        fns_cache[[bk]] <<- tryCatch(backend_status_fns(bk),
                                     error = function(e) list(squeue_fn = NULL, sacct_fn = NULL))
      }
      fns_cache[[bk]]
    }
    for (r in recs) {
      lr <- if (length(r$last_result) && nzchar(r$last_result)) r$last_result else ""
      lab <- ""
      if (!isTRUE(r$done)) {
        if (live_budget > 0) {
          live_budget <- live_budget - 1L
          rbk <- as.character(r$backend %||% "slurm")[1]
          if (is.na(rbk) || !nzchar(rbk)) rbk <- "slurm"
          fns <- get_fns(rbk)
          lp <- tryCatch(backend_log_paths(r$jobid, r$out_dir, rbk, r$script_path),
                         error = function(e) list(out = ""))
          logf <- if (length(r$log_out) == 1 && !is.na(r$log_out) && nzchar(r$log_out)) r$log_out else lp$out
          st <- tryCatch(
            diann_job_status(r$jobid, r$out_dir, r$out_file,
                             script_path = r$script_path, submitted = r$submitted,
                             squeue_fn = fns$squeue_fn, sacct_fn = fns$sacct_fn,
                             log_path = logf),
            error = function(e) NULL)
          if (!is.null(st)) lab <- sprintf("[%s] %s ", st$label, st$reason)
        }
      } else if (!is.null(r$status_label) && nzchar(r$status_label)) {
        rs <- if (!is.null(r$status_reason) && nzchar(r$status_reason)) paste0(" (", r$status_reason, ")") else ""
        lab <- paste0("[", r$status_label, "]", rs, " ")
      }
      lines <- c(lines, sprintf("Job %s → %s [%s] %s%s",
                                r$jobid, r$to, if (isTRUE(r$done)) "已处理" else "等待完成…", lab, lr))
    }
    paste(lines, collapse = "\n")
  })

  # 取消作业 (弹窗确认)
  observeEvent(input$cancel_btn, {
    jid <- suppressWarnings(as.integer(input$cancel_id))
    if (is.na(jid)) {
      showNotification("请先输入要取消的作业 ID", type = "error")
      return()
    }
    showModal(modalDialog(
      title = "确认取消作业",
      sprintf("确认取消%s作业 %d 吗? 该操作不可撤销。", if (is_local) "本地" else " Slurm ", jid),
      footer = tagList(
        modalButton("返回"),
        actionButton("cancel_confirm", "确认取消", class = "btn-danger")
      )
    ))
  })
  observeEvent(input$cancel_confirm, {
    removeModal()
    jid <- suppressWarnings(as.integer(input$cancel_id))
    if (is.na(jid)) {
      showNotification("作业 ID 无效", type = "error")
      return()
    }
    # backend_cancel 内部已 tryCatch (slurm: scancel; local: 标记 + 进程组 kill)
    res <- backend_cancel(jid, backend = backend)
    if (isTRUE(res$ok)) {
      showNotification(sprintf("✔ %s", res$message), type = "message")
    } else {
      showNotification(paste("✗", res$message), type = "warning")
    }
  })

  # 日志查看: 按 JobID 自动定位。v1.12 起日志文件名由 backend_log_paths() 唯一决定
  # (slurm-<id>.out / local-<id>.out); 旧 slurm 记录仍可经注册表/手动目录定位。
  locate_job_log <- function(jid_int) {
    jid_num <- suppressWarnings(as.integer(jid_int))
    fnames <- character(0)
    if (!is.na(jid_num)) {
      fnames <- c(basename(backend_log_paths(jid_num, "/x", "slurm")$out),
                  basename(backend_log_paths(jid_num, "/x", "local")$out))
    }
    fnames <- unique(fnames[nzchar(fnames)])
    dirs <- unique(c(if (length(selected_log_dir())) selected_log_dir() else character(0),
                     jobs$jobs[["输出目录"]]))
    for (d in dirs) {
      for (fn in fnames) {
        cand <- file.path(d, fn)
        if (file.exists(cand)) {
          return(list(path = cand, src = if (identical(d, selected_log_dir()[1])) "手动指定目录" else "本会话提交记录"))
        }
      }
    }
    reg <- jobs_registry_load()
    hit <- reg[reg$jobid == as.character(jid_int), , drop = FALSE]
    if (nrow(hit) && file.exists(hit$日志[nrow(hit)])) {
      return(list(path = hit$日志[nrow(hit)], src = "GUI 提交注册表"))
    }
    # 本地作业记录里也存了日志完整路径 (注册表缺失/滚动淘汰时兜底)
    rec <- tryCatch(local_jobs_find(jid_int), error = function(e) NULL)
    if (!is.null(rec) && length(rec$log_out) == 1 && nzchar(rec$log_out %||% "") && file.exists(rec$log_out)) {
      return(list(path = rec$log_out, src = "本地作业记录"))
    }
    if (identical(backend, "slurm")) {
      # Slurm 侧兜底: scontrol 实时信息 → sacct 工作目录 (全部 tryCatch;
      # no-Slurm 环境下不再因捕获输出的 system()/system2() 抛错而中断)
      sc <- tryCatch(
        suppressWarnings(system2("scontrol", c("show", "job", as.character(jid_int)),
                                 stdout = TRUE, stderr = TRUE)),
        error = function(e) character(0))
      mo <- regmatches(paste(sc, collapse = " "), regexpr("StdOut=\\S+", paste(sc, collapse = " ")))
      if (length(mo)) {
        cand <- sub("^StdOut=", "", mo)
        if (file.exists(cand)) return(list(path = cand, src = "scontrol (Slurm 实时信息)"))
      }
      sw <- tryCatch(
        suppressWarnings(system(sprintf("sacct -j %d -X -n -o workdir%%250 2>/dev/null", jid_int), intern = TRUE)),
        error = function(e) character(0))
      if (length(sw) && nzchar(trimws(sw[1]))) {
        cand <- file.path(trimws(sw[1]), fnames[1])
        if (file.exists(cand)) return(list(path = cand, src = "sacct 工作目录"))
      }
    }
    NULL
  }
  log_text <- eventReactive(input$view_log, {
    jid <- input$log_id
    if (is.null(jid) || is.na(jid)) return("请先输入作业 ID")
    jid_int <- suppressWarnings(as.integer(jid))
    hit <- locate_job_log(jid_int)
    if (is.null(hit)) {
      dmsg <- if (length(selected_log_dir())) sprintf("手动目录: %s", selected_log_dir()) else "未手动指定日志目录"
      tried <- if (is_local) {
        "手动目录 → 本会话提交记录 → GUI 提交注册表 → 本地作业记录"
      } else {
        "手动目录 → 本会话提交记录 → GUI 提交注册表 → scontrol (Slurm) → sacct 工作目录"
      }
      hint <- if (is_local) {
        "说明: 本地模式日志为 local-<ID>.out/.err, 位于作业的输出目录。"
      } else {
        paste0("说明: 运行中/排队中/刚结束的作业可经 scontrol 定位; 本 GUI 提交的作业永久记录在注册表;\n",
               "早已结束且非本 GUI 提交的作业, Slurm 记账库不保存日志路径 (20.11), 请手动指定日志目录。")
      }
      return(paste0(sprintf("未能自动定位作业 %d 的日志。\n", jid_int),
                    "已依次尝试: ", tried, "。\n", dmsg, "\n", hint))
    }
    txt <- tryCatch(
      suppressWarnings(system2("tail", c("-n", "120", shQuote(hit$path)), stdout = TRUE, stderr = TRUE)),
      error = function(e) character(0))
    header <- sprintf("=== %s (尾部 %d 行, 来源: %s) ===\n", hit$path, length(txt), hit$src)
    err_part <- ""
    errf <- sub("\\.out$", ".err", hit$path)
    if (file.exists(errf)) {
      etxt <- tryCatch(
        suppressWarnings(system2("tail", c("-n", "30", shQuote(errf)), stdout = TRUE, stderr = TRUE)),
        error = function(e) character(0))
      etxt <- etxt[nzchar(trimws(etxt))]
      if (length(etxt)) err_part <- sprintf("\n\n=== %s (尾部 %d 行, 程序报错通常在这里) ===\n%s",
                                            errf, length(etxt), paste(etxt, collapse = "\n"))
    }
    paste0(header, paste(txt, collapse = "\n"), err_part)
  })
  output$log_output <- renderText(log_text())

  # ---------- 参数速查 ----------
  output$doc_path_display <- renderText({
    if (!is.null(cfg_get("param_ref"))) {
      # PARAM_DOC 由 run_app() 写入; 未走 run_app 时回退 param_doc_path() (避免 sprintf(NULL) -> character(0) 空白)
      pd <- cfg_get("PARAM_DOC")
      if (!nz_str(pd)) pd <- param_doc_path()
      sprintf("来源: %s (共 %d 个参数)\n官方文档: https://github.com/vdemichev/DiaNN", pd, nrow(cfg_get("param_ref")))
    } else "未找到参数说明文档 — 请自行从 DIA-NN 官方仓库获取命令行参考, 存为工作目录下的 DIANN_param_reference.md (v1.13 起不再随包分发)"
  })
  output$param_ref <- renderUI({
    if (is.null(cfg_get("param_ref"))) return(NULL)
    tags$ul(lapply(seq_len(nrow(cfg_get("param_ref"))), function(i) {
      tags$li(tags$strong(cfg_get("param_ref")$flag[i]), " — ", cfg_get("param_ref")$desc[i])
    }))
  })

  # ---------- 更新说明 ----------
  output$version_notes <- renderUI({
    r <- sif_rows()
    if (!nrow(r)) return(tags$p("未扫描到 sif 镜像, 请检查 config.R 中的 SIF_DIRS"))
    n_ok <- sum(r$verified)
    # 只对有实测记录的版本宣称"三种模式实测" (任意新识别版本不自动获得该背书, 审查 P2)
    tested <- names(DIANN_VERSION_NOTES)
    n_tested <- sum(r$ver %in% tested, na.rm = TRUE)
    tags$div(
      tags$p(style = "color:#27ae60;",
             sprintf("✔ 共 %d 个镜像, 已识别 %d 个 (其中 %d 个在 GUI 三种模式实测通过: RAW→DIA 转换 / 直接搜库+MBR+污染物扣除 / FASTA 生成预测库); 其余已识别版本尚无实测记录, 升级生产数据前建议先跑小样本回归。",
                     nrow(r), n_ok, n_tested)),
      tags$ul(lapply(seq_len(nrow(r)), function(i) {
        if (isTRUE(r$verified[i])) {
          note <- DIANN_VERSION_NOTES[[r$ver[i]]] %||% "暂无实测说明。"
          tags$li(tags$strong(sprintf("DIA-NN %s", r$ver[i])), " — ", note, tags$br(), tags$code(r$path[i]))
        } else {
          msg <- if (nzchar(r$probe_message[i])) r$probe_message[i] else
            "版本未识别 — 在「2. DIA-NN 版本」选中后自动识别, 或点「识别所有未识别镜像」。"
          tags$li(tags$strong("版本未识别"), " — ", msg, tags$br(), tags$code(r$path[i]))
        }
      }))
    )
  })
  output$diann_release_notes <- renderUI({
    tags$div(lapply(DIANN_RELEASE_NOTES, function(e) {
      tags$div(
        h5(tags$strong(sprintf("DIA-NN %s", e$ver)),
           tags$small(sprintf("  (%s · %s)", e$date, e$channel))),
        if (length(e$notes)) tags$ul(style = "color:#8a6d3b; margin-top:2px;",
                                     lapply(e$notes, tags$li)),
        tags$ul(lapply(e$items, tags$li))
      )
    }))
  })
  output$sif_table <- renderTable({
    r <- sif_rows()
    if (!nrow(r)) return(data.frame(提示 = "未扫描到 sif 镜像", stringsAsFactors = FALSE))
    data.frame(版本 = ifelse(r$verified, sprintf("v%s", r$ver), "未识别"),
               sif路径 = r$path,
               `大小(GB)` = round(r$size / 1024^3, 2),
               修改日期 = format(as.POSIXct(r$mtime, origin = "1970-01-01", tz = "UTC"), "%Y-%m-%d"),
               状态 = ifelse(r$verified, "已识别",
                             ifelse(nzchar(r$probe_message), "上次识别失败", "未识别")),
               stringsAsFactors = FALSE, check.names = FALSE)
  }, striped = TRUE, bordered = TRUE)
  output$gui_changelog <- renderUI({
    tags$div(lapply(CHANGELOG, function(e) {
      tags$div(
        h5(tags$strong(e$ver), tags$small(sprintf("  (%s)", e$date))),
        tags$ul(lapply(e$items, tags$li))
      )
    }))
  })
}

}
