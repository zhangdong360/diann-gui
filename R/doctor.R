# ============================================================
# doctor.R — R 内运行环境自检
#
# 自托管交付下每个用户自己安装包、自己启动, 出问题时最难定位的是
# "缺依赖 / 没 Slurm 命令 / 找不到 apptainer / SIF_DIRS 没配 / 状态目录不可写"。
# doctor() 一次性列出这些检查项, 供用户复制给管理员。只读, 不修改任何文件。
# ============================================================

#' 运行环境自检
#'
#' 检查 R 版本、依赖包、Slurm 命令、分区、apptainer 候选、SIF 目录、
#' 配置/邮件配置/状态目录与运行身份，返回并打印检查表。
#' 所有探测都可注入，便于离线测试。
#'
#' @param apptainer_cands apptainer 候选 data.frame (默认调用 apptainer_candidates())
#' @param partitions Slurm 分区 (默认 sinfo 探测)
#' @param slurm_cmds 命名字符向量: 命令名 -> 路径 (默认 Sys.which)
#' @param sif_dirs SIF 目录 (默认 detect_sif_dirs())
#' @param mail_conf 邮件配置文件路径 (默认 cfg_get("MAIL_CONF"))
#' @param state_dir 状态目录 (默认 dirname(cfg_get("NOTIFY_STATE")))
#' @param deps 需要检查的依赖包
#' @return data.frame(check, status, detail) (invisible)
#' @export
doctor <- function(apptainer_cands = NULL, partitions = NULL, slurm_cmds = NULL,
                   sif_dirs = NULL, mail_conf = NULL, state_dir = NULL,
                   deps = c("shiny", "shinydashboard", "shinyFiles", "htmltools")) {
  rows <- list()
  add <- function(check, status, detail = "") {
    rows[[length(rows) + 1L]] <<- data.frame(check = check, status = status,
                                             detail = as.character(detail)[1],
                                             stringsAsFactors = FALSE)
  }

  add("R 版本", if (getRversion() >= "4.1.0") "ok" else "fail", as.character(getRversion()))
  add("diann.gui 版本", "ok", tryCatch(as.character(utils::packageVersion("diann.gui")),
                                       error = function(e) "未知"))
  for (d in deps) {
    ok <- isTRUE(requireNamespace(d, quietly = TRUE))
    add(sprintf("依赖包 %s", d), if (ok) "ok" else "fail",
        if (ok) tryCatch(as.character(utils::packageVersion(d)), error = function(e) "") else "未安装")
  }

  if (is.null(slurm_cmds)) {
    cmds <- c("sbatch", "squeue", "sacct", "sinfo", "scontrol")
    slurm_cmds <- stats::setNames(vapply(cmds, function(x) unname(Sys.which(x)), ""), cmds)
  }
  for (nm in names(slurm_cmds)) {
    p <- unname(slurm_cmds[[nm]])
    add(sprintf("Slurm 命令 %s", nm), if (nzchar(p)) "ok" else "fail",
        if (nzchar(p)) p else "PATH 上找不到 (不在提交节点?)")
  }

  if (is.null(partitions)) partitions <- tryCatch(detect_slurm_partitions(), error = function(e) character(0))
  add("Slurm 分区", if (length(partitions)) "ok" else "warn",
      if (length(partitions)) paste(partitions, collapse = ", ") else "sinfo 无输出 (未配置 Slurm?)")

  if (is.null(apptainer_cands)) apptainer_cands <- tryCatch(apptainer_candidates(), error = function(e) NULL)
  if (!is.null(apptainer_cands) && nrow(apptainer_cands)) {
    ok <- apptainer_cands[apptainer_cands$ok, , drop = FALSE]
    add("apptainer", if (nrow(ok)) "ok" else "warn",
        if (nrow(ok)) sprintf("%d 个可用: %s", nrow(ok),
                              paste(sprintf("%s %s", ok$kind, ok$version), collapse = "; "))
        else "识别到可执行文件但版本解析失败, 可在 GUI 手动验证")
  } else {
    add("apptainer", "warn", "未自动识别到; 可在 GUI「1. apptainer 运行环境」手动指定路径")
  }

  # 版本下限单独一行: 2.x 的 --version 正常、看起来"可用", 但读不了 SIF —— 最容易踩的坑
  sif_cands <- tryCatch(apptainer_cands_sif(apptainer_cands), error = function(e) NULL)
  if (!is.null(sif_cands) && nrow(sif_cands)) {
    good <- sif_cands[sif_cands$ok & !is.na(sif_cands$sif_ok) & sif_cands$sif_ok, , drop = FALSE]
    bad <- sif_cands[sif_cands$ok & !is.na(sif_cands$sif_ok) & !sif_cands$sif_ok, , drop = FALSE]
    if (nrow(good)) {
      add(sprintf("SIF 运行时 (%s)", sif_min_version_text()), "ok",
          paste(sprintf("%s %s", good$kind, good$version), collapse = "; "))
    } else if (nrow(bad)) {
      add(sprintf("SIF 运行时 (%s)", sif_min_version_text()), "fail",
          sprintf("候选均读不了 .sif: %s (2.x 只支持 squashfs/ext3 的 .simg; 请改选或升级)",
                  paste(sprintf("%s %s", bad$kind, bad$version), collapse = "; ")))
    } else {
      add(sprintf("SIF 运行时 (%s)", sif_min_version_text()), "warn",
          "版本未解析, 无法判定; 在 GUI 用「识别并验证」确认")
    }
  }

  if (is.null(sif_dirs)) sif_dirs <- tryCatch(detect_sif_dirs(), error = function(e) character(0))
  n_sif <- if (length(sif_dirs)) {
    sum(vapply(sif_dirs, function(d) length(list.files(d, pattern = "(?i)^diann.*\\.sif$")), integer(1)))
  } else 0L
  add("SIF 镜像", if (n_sif > 0) "ok" else "warn",
      if (n_sif > 0) sprintf("%d 个, 目录: %s", n_sif, paste(sif_dirs, collapse = ", "))
      else "未发现 diann*.sif; 可在 config.R 设置 SIF_DIRS, 或在 GUI 手动输入镜像路径")

  dh <- cfg_get("DATA_HOME") %||% ""
  add("DATA_HOME", if (nzchar(dh) && dir.exists(dh) && file.access(dh, 4) == 0) "ok" else "warn",
      if (nzchar(dh)) sprintf("%s%s", dh, if (dir.exists(dh) && file.access(dh, 4) == 0) "" else " (不可读)") else "(未设置)")
  bv <- tryCatch(unname(cfg_get("BASE_VOLUMES") %||% character(0)), error = function(e) character(0))
  add("可浏览数据根", if (length(bv)) "ok" else "warn", paste(bv, collapse = ", "))

  config_file <- cfg_get("CONFIG_FILE") %||% ""
  if (!nzchar(config_file)) config_file <- tryCatch(resolve_user_config(), error = function(e) "")
  add("配置文件", if (nzchar(config_file) && file.exists(config_file)) "ok" else "warn",
      if (nzchar(config_file)) config_file else "未找到 (使用内置默认; 可运行 diann.gui::init_config())")

  if (is.null(mail_conf)) mail_conf <- cfg_get("MAIL_CONF") %||% ""
  if (nzchar(mail_conf) && file.exists(mail_conf)) {
    mode_dec <- as.integer(file.info(mail_conf)$mode)
    world_bits <- bitwAnd(mode_dec, 63L)   # 组/其他用户权限位
    add("邮件配置", if (world_bits == 0L) "ok" else "warn",
        sprintf("%s (%s)", mail_conf, if (world_bits == 0L) "权限 600, 安全" else "权限过宽, 建议 chmod 600"))
  } else {
    add("邮件配置", "warn", "未找到 (邮件通知停用; 参考 inst/config/mail_config.example.txt)")
  }

  if (is.null(state_dir)) state_dir <- dirname(cfg_get("NOTIFY_STATE") %||% tempdir())
  add("状态目录", if (dir.exists(state_dir) && file.access(state_dir, 2) == 0) "ok" else "fail",
      sprintf("%s%s", state_dir, if (dir.exists(state_dir) && file.access(state_dir, 2) == 0) "" else " (不可写)"))

  add("运行身份", "ok", sprintf("%s @ %s (HOME=%s)", Sys.info()[["user"]],
                                 Sys.info()[["nodename"]], path.expand("~")))

  df <- do.call(rbind, rows)
  print(df, row.names = FALSE)
  n_fail <- sum(df$status == "fail")
  n_warn <- sum(df$status == "warn")
  message(sprintf("自检完成: %d 项通过, %d 项警告, %d 项失败", sum(df$status == "ok"), n_warn, n_fail))
  invisible(df)
}
