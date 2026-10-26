# ============================================================
# doctor.R — R 内运行环境自检
#
# 自托管交付下每个用户自己安装包、自己启动, 出问题时最难定位的是
# "缺依赖 / 执行后端选错 / 没 Slurm 命令 / 缺本地执行原语 / 找不到 apptainer /
#  SIF_DIRS 没配 / 状态目录不可写"。
# doctor() 一次性列出这些检查项, 供用户复制给管理员。只读, 不修改任何文件。
# v1.12: 按执行后端 (slurm/local) 分级——Slurm 模式检查 sbatch/squeue 等命令与分区,
#        本地模式这些项降级为 na, 改为检查 setsid/nohup/timeout/bash 与 /proc。
# v1.13: 按重要性重排分组 [0]执行后端 → [1]R → [2]依赖包(本地模式含原语) →
#        [3]apptainer → [4]SIF 镜像(含识别状态, 只读缓存) → [5]其他环境(含本地
#        作业状态文件) → [6]Slurm 依赖(最后, 本地模式合并 1 行 na); 输出带组标题/
#        状态符号/对齐/汇总; 返回 df 新增 group 列 (check/status/detail 保留)。
# ============================================================

#' 运行环境自检
#'
#' 按重要性分组检查并打印: [0] 执行后端、[1] R 环境、[2] 依赖包
#' (本地模式追加 setsid/nohup/timeout/bash 与 /proc)、[3] apptainer 依赖、
#' [4] SIF 镜像 (目录/数量/容器识别状态, 只读缓存不跑容器)、[5] 其他环境
#' (DATA_HOME/数据根/配置/邮件/状态目录/运行身份/本地作业状态文件)、
#' [6] Slurm 依赖 (本地模式合并为一行不适用)。
#' 所有探测都可注入，便于离线测试；不修改任何文件。
#'
#' @param apptainer_cands apptainer 候选 data.frame (默认调用 apptainer_candidates())
#' @param partitions Slurm 分区 (默认 sinfo 探测; 本地模式不探测)
#' @param slurm_cmds 命名字符向量: 命令名 -> 路径 (默认 Sys.which)
#' @param sif_dirs SIF 目录 (默认 detect_sif_dirs())
#' @param sif_probe SIF 版本识别缓存 (默认 sif_probe_load(); 只读, 不跑容器)
#' @param mail_conf 邮件配置文件路径 (默认 cfg_get("MAIL_CONF"))
#' @param state_dir 状态目录 (默认 dirname(cfg_get("NOTIFY_STATE")))
#' @param deps 需要检查的依赖包
#' @param backend 执行后端 "slurm"/"local"; NULL = 用配置解析结果 (默认 slurm)
#' @param local_cmds 命名字符向量: 本地原语命令名 -> 路径 (默认 Sys.which)
#' @return data.frame(group, check, status, detail) (invisible)
#' @export
doctor <- function(apptainer_cands = NULL, partitions = NULL, slurm_cmds = NULL,
                   sif_dirs = NULL, sif_probe = NULL, mail_conf = NULL, state_dir = NULL,
                   deps = c("shiny", "shinydashboard", "shinyFiles", "htmltools"),
                   backend = NULL, local_cmds = NULL) {
  groups <- c("执行后端", "R 环境", "依赖包", "apptainer 依赖", "SIF 镜像", "其他环境",
              "结果分析依赖", "Slurm 依赖")
  rows <- list()
  add <- function(group, check, status, detail = "") {
    rows[[length(rows) + 1L]] <<- list(group = group, check = check, status = status,
                                       detail = as.character(detail)[1])
  }

  # ---- [0] 执行后端: 注入优先 > 配置解析结果 > slurm (v1.11 唯一行为) ----
  backend_injected <- !is.null(backend) && length(backend) > 0 &&
    !is.na(backend[1]) && nzchar(trimws(as.character(backend[1])))
  binfo <- tryCatch(cfg_get("EXEC_BACKEND_INFO"), error = function(e) NULL)
  if (!backend_injected) {
    # 默认走 backend_info() (与 run_app/server 使用同一解析结果; 测试可注入
    # .cfg$EXEC_BACKEND_INFO 覆盖); 解析失败才退回字符串缓存。
    info <- tryCatch(backend_info(), error = function(e) NULL)
    if (!is.null(info) && !is.null(info$backend) &&
        length(info$backend) == 1 && !is.na(info$backend) && nzchar(as.character(info$backend))) {
      backend <- info$backend
      binfo <- info
    } else {
      backend <- cfg_get("EXEC_BACKEND_RESOLVED") %||% "slurm"
    }
  }
  backend <- tolower(trimws(as.character(backend)[1]))
  if (!backend %in% c("slurm", "local")) backend <- "slurm"
  backend_how <- if (backend_injected || !isTRUE(binfo$auto)) "配置指定" else "自动检测"
  add(groups[1], "执行后端", "ok",
      sprintf("%s (%s; %s)", backend_label(backend),
              backend_how, if (identical(backend, "local")) "无 Slurm, 本机执行" else "sbatch 提交队列"))

  # ---- [1] R 环境 ----
  add(groups[2], "R 版本", if (getRversion() >= "4.1.0") "ok" else "fail", as.character(getRversion()))
  add(groups[2], "diann.gui 版本", "ok",
      tryCatch(as.character(utils::packageVersion("diann.gui")), error = function(e) "未知"))

  # ---- [2] 依赖包 (本地模式追加本地执行原语) ----
  for (d in deps) {
    ok <- isTRUE(requireNamespace(d, quietly = TRUE))
    add(groups[3], sprintf("依赖包 %s", d), if (ok) "ok" else "fail",
        if (ok) tryCatch(as.character(utils::packageVersion(d)), error = function(e) "") else "未安装")
  }
  if (identical(backend, "local")) {
    if (is.null(local_cmds)) {
      nm4 <- c("setsid", "nohup", "timeout", "bash")
      local_cmds <- stats::setNames(vapply(nm4, function(x) unname(Sys.which(x)), ""), nm4)
    }
    for (nm in names(local_cmds)) {
      p <- unname(local_cmds[[nm]])
      ok <- nzchar(p) && file.access(p, 1) == 0
      detail <- if (ok) {
        p
      } else if (!nzchar(p)) {
        if (identical(nm, "setsid")) "PATH 上找不到 (可退化: 取消改为递归子树 kill)"
        else "PATH 上找不到 (本地模式必需)"
      } else {
        sprintf("%s (文件不可执行)", p)
      }
      add(groups[3], sprintf("本地原语 %s", nm), if (ok) "ok" else "warn", detail)
    }
    proc_ok <- file.exists("/proc/self/stat") && file.access("/proc/self/stat", 4) == 0
    add(groups[3], "本地 /proc", if (proc_ok) "ok" else "warn",
        if (proc_ok) "可读 (本地作业判活/取消依赖)" else "不可读: 本地作业判活与取消会退化")
  }

  # ---- [3] apptainer 依赖 ----
  if (is.null(apptainer_cands)) apptainer_cands <- tryCatch(apptainer_candidates(), error = function(e) NULL)
  if (!is.null(apptainer_cands) && nrow(apptainer_cands)) {
    ok <- apptainer_cands[apptainer_cands$ok, , drop = FALSE]
    add(groups[4], "apptainer", if (nrow(ok)) "ok" else "warn",
        if (nrow(ok)) sprintf("%d 个可用: %s", nrow(ok),
                              paste(sprintf("%s %s", ok$kind, ok$version), collapse = "; "))
        else "识别到可执行文件但版本解析失败, 可在 GUI 手动验证")
  } else {
    add(groups[4], "apptainer", "warn", "未自动识别到; 可在 GUI「1. apptainer 运行环境」手动指定路径")
  }
  # 版本下限单独一行: 2.x 的 --version 正常、看起来"可用", 但读不了 SIF —— 最容易踩的坑
  sif_cands <- tryCatch(apptainer_cands_sif(apptainer_cands), error = function(e) NULL)
  if (!is.null(sif_cands) && nrow(sif_cands)) {
    good <- sif_cands[sif_cands$ok & !is.na(sif_cands$sif_ok) & sif_cands$sif_ok, , drop = FALSE]
    bad <- sif_cands[sif_cands$ok & !is.na(sif_cands$sif_ok) & !sif_cands$sif_ok, , drop = FALSE]
    if (nrow(good)) {
      add(groups[4], sprintf("SIF 运行时 (%s)", sif_min_version_text()), "ok",
          paste(sprintf("%s %s", good$kind, good$version), collapse = "; "))
    } else if (nrow(bad)) {
      add(groups[4], sprintf("SIF 运行时 (%s)", sif_min_version_text()), "fail",
          sprintf("候选均读不了 .sif: %s (2.x 只支持 squashfs/ext3 的 .simg; 请改选或升级)",
                  paste(sprintf("%s %s", bad$kind, bad$version), collapse = "; ")))
    } else {
      add(groups[4], sprintf("SIF 运行时 (%s)", sif_min_version_text()), "warn",
          "版本未解析, 无法判定; 在 GUI 用「识别并验证」确认")
    }
  }

  # ---- [4] SIF 镜像: 目录 + 数量 + 识别状态 (只读缓存, 不跑容器) ----
  if (is.null(sif_dirs)) {
    sif_dirs <- tryCatch(unname(cfg_get("SIF_DIRS") %||% character(0)), error = function(e) character(0))
    if (!length(sif_dirs)) sif_dirs <- tryCatch(detect_sif_dirs(), error = function(e) character(0))
  }
  if (is.null(sif_probe)) sif_probe <- tryCatch(sif_probe_load(), error = function(e) NULL)
  if (is.null(sif_probe) || !is.list(sif_probe$entries)) sif_probe <- list(entries = list())
  sif_scan <- tryCatch(sif_merge_probe(scan_sif_images(sif_dirs), sif_probe),
                       error = function(e) NULL)
  n_all <- if (is.null(sif_scan)) 0L else nrow(sif_scan)
  n_ver <- if (is.null(sif_scan)) 0L else sum(sif_scan$verified)
  add(groups[5], "SIF 目录", if (length(sif_dirs)) "ok" else "warn",
      if (length(sif_dirs)) paste(sif_dirs, collapse = ", ")
      else "未发现含 .sif 的目录; 可在 config.R 设置 SIF_DIRS (任意文件名)")
  add(groups[5], "SIF 镜像", if (n_all > 0) "ok" else "warn",
      if (n_all > 0) sprintf("%d 个 *.sif (文件名无关)", n_all)
      else "未发现 .sif; 构建/放置后自动出现在 GUI 下拉 (README 见构建章节)")
  if (n_all > 0) {
    un_id <- sif_scan[!sif_scan$verified, , drop = FALSE]
    fail_info <- un_id[nzchar(un_id$probe_message), , drop = FALSE]
    add(groups[5], "SIF 版本识别",
        if (n_ver == n_all) "ok" else "warn",   # 未识别 0/N 也提示 (GUI 里点按钮识别)
        if (n_ver == n_all) sprintf("已识别 %d/%d (容器内实测)", n_ver, n_all)
        else sprintf("已识别 %d/%d; 未识别 %d 个%s", n_ver, n_all, nrow(un_id),
                     if (nrow(fail_info))
                       sprintf(" (上次失败: %s — %s)", basename(fail_info$path[1]),
                               substr(fail_info$probe_message[1], 1, 80))
                     else " — 在 GUI 选中自动识别或点「识别所有未识别镜像」"))
  }

  # ---- [5] 其他环境 ----
  dh <- cfg_get("DATA_HOME") %||% ""
  add(groups[6], "DATA_HOME", if (nzchar(dh) && dir.exists(dh) && file.access(dh, 4) == 0) "ok" else "warn",
      if (nzchar(dh)) sprintf("%s%s", dh, if (dir.exists(dh) && file.access(dh, 4) == 0) "" else " (不可读)") else "(未设置)")
  bv <- tryCatch(unname(cfg_get("BASE_VOLUMES") %||% character(0)), error = function(e) character(0))
  add(groups[6], "可浏览数据根", if (length(bv)) "ok" else "warn", paste(bv, collapse = ", "))

  config_file <- cfg_get("CONFIG_FILE") %||% ""
  if (!nzchar(config_file)) config_file <- tryCatch(resolve_user_config(), error = function(e) "")
  add(groups[6], "配置文件", if (nzchar(config_file) && file.exists(config_file)) "ok" else "warn",
      if (nzchar(config_file)) config_file else "未找到 (使用内置默认; 可运行 diann.gui::init_config())")

  if (is.null(mail_conf)) mail_conf <- cfg_get("MAIL_CONF") %||% ""
  if (nzchar(mail_conf) && file.exists(mail_conf)) {
    mode_dec <- as.integer(file.info(mail_conf)$mode)
    world_bits <- bitwAnd(mode_dec, 63L)   # 组/其他用户权限位
    add(groups[6], "邮件配置", if (world_bits == 0L) "ok" else "warn",
        sprintf("%s (%s)", mail_conf, if (world_bits == 0L) "权限 600, 安全" else "权限过宽, 建议 chmod 600"))
  } else {
    add(groups[6], "邮件配置", "warn", "未找到 (邮件通知停用; 参考 inst/config/mail_config.example.txt)")
  }

  if (is.null(state_dir)) state_dir <- dirname(cfg_get("NOTIFY_STATE") %||% tempdir())
  add(groups[6], "状态目录", if (dir.exists(state_dir) && file.access(state_dir, 2) == 0) "ok" else "fail",
      sprintf("%s%s", state_dir, if (dir.exists(state_dir) && file.access(state_dir, 2) == 0) "" else " (不可写)"))

  # 本地作业状态文件 (只读; 损坏时 doctor 可见告警)
  if (identical(backend, "local")) {
    st <- tryCatch(local_jobs_status(), error = function(e) list(ok = FALSE, detail = conditionMessage(e), warn = ""))
    status <- if (isTRUE(st$ok)) (if (nzchar(st$warn %||% "")) "warn" else "ok") else "fail"
    detail <- st$detail
    if (nzchar(st$warn %||% "")) detail <- sprintf("%s (%s)", detail, substr(st$warn, 1, 120))
    add(groups[6], "本地作业状态文件", status, detail)
  } else {
    add(groups[6], "本地作业状态文件", "na", "Slurm 模式未使用本地作业状态文件")
  }

  add(groups[6], "运行身份", "ok", sprintf("%s @ %s (HOME=%s)", Sys.info()[["user"]],
                                           Sys.info()[["nodename"]], path.expand("~")))

  # ---- [6.5] 结果分析依赖 (v1.14 可选模块; 缺包不阻断主链, 只给安装命令) ----
  adf <- tryCatch(an_deps_check(), error = function(e) NULL)
  if (!is.null(adf) && nrow(adf)) {
    amiss <- adf[!adf$installed, , drop = FALSE]
    add(groups[7], "分析依赖包", if (nrow(amiss)) "warn" else "ok",
        if (nrow(amiss))
          sprintf("缺失 %d/%d: %s (安装: %s)", nrow(amiss), nrow(adf),
                  paste(amiss$pkg, collapse = ", "),
                  paste(an_deps_install_hint(amiss$pkg, amiss$bioc), collapse = "; "))
        else sprintf("全部就绪 (%d 个)", nrow(adf)))
    aopt <- an_deps_optional()
    aopt_miss <- names(aopt)[!vapply(names(aopt), requireNamespace, logical(1), quietly = TRUE)]
    add(groups[7], "分析可选增强", if (length(aopt_miss)) "warn" else "ok",
        if (length(aopt_miss))
          paste(sprintf("%s (%s)", aopt_miss, unname(aopt[aopt_miss])), collapse = "; ")
        else "全部就绪")
  }

  # ---- [7] Slurm 依赖 (最后; 本地模式合并 1 行 na) ----
  if (identical(backend, "slurm")) {
    if (is.null(slurm_cmds)) {
      cmds <- c("sbatch", "squeue", "sacct", "sinfo", "scontrol")
      slurm_cmds <- stats::setNames(vapply(cmds, function(x) unname(Sys.which(x)), ""), cmds)
    }
    for (nm in names(slurm_cmds)) {
      p <- unname(slurm_cmds[[nm]])
      if (!nzchar(p)) {
        add(groups[8], sprintf("Slurm 命令 %s", nm), "fail", "PATH 上找不到 (不在提交节点?)")
      } else if (file.access(p, 1) != 0) {
        add(groups[8], sprintf("Slurm 命令 %s", nm), "fail", sprintf("%s (文件不可执行)", p))
      } else {
        add(groups[8], sprintf("Slurm 命令 %s", nm), "ok", p)
      }
    }
    if (is.null(partitions)) partitions <- tryCatch(detect_slurm_partitions(), error = function(e) character(0))
    add(groups[8], "Slurm 分区", if (length(partitions)) "ok" else "warn",
        if (length(partitions)) paste(partitions, collapse = ", ") else "sinfo 无输出 (未配置 Slurm?)")
  } else {
    add(groups[8], "Slurm 依赖", "na", "本地模式未启用 (可选后端)")
  }

  # ---- 输出: 组标题 + 符号 + 对齐 + 汇总 ----
  df <- do.call(rbind, lapply(rows, function(r) data.frame(group = r$group, check = r$check,
                                                           status = r$status, detail = r$detail,
                                                           stringsAsFactors = FALSE)))
  sym <- c(ok = "✓", warn = "⚠", fail = "✗", na = "–")
  # 显示宽度: CJK/全角按 2 计 (nchar(type="width") 随 locale 变化, 在 C locale 下
  # 中文按 1 计导致列错位 — 审查 P2)
  disp_w <- function(s) {
    n <- nchar(s)
    wide <- lengths(regmatches(s, gregexpr(
      "[\u2E80-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF]", s, perl = TRUE)))
    n + wide
  }
  pad <- function(s, w) {
    d <- disp_w(s)
    if (d >= w) s else paste0(s, strrep(" ", w - d))
  }
  w <- max(disp_w(df$check), na.rm = TRUE)
  for (g in groups) {
    sub <- df[df$group == g, , drop = FALSE]
    if (!nrow(sub)) next
    cat(sprintf("── [%d] %s ──\n", match(g, groups) - 1L, g))
    for (i in seq_len(nrow(sub))) {
      cat(sprintf("  %s %s  %s\n", sym[[sub$status[i]]], pad(sub$check[i], w), sub$detail[i]))
    }
  }
  n_ok <- sum(df$status == "ok"); n_warn <- sum(df$status == "warn")
  n_fail <- sum(df$status == "fail"); n_na <- sum(df$status == "na")
  message(sprintf("汇总: ✓ %d  ⚠ %d  ✗ %d  – %d  (共 %d 项, 环境: %s)",
                  n_ok, n_warn, n_fail, n_na, nrow(df), backend_label(backend)))
  invisible(df)
}
