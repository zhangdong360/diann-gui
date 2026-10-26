# ============================================================
# init-config.R — 在 R 内生成每用户配置文件 (替代旧的 bin/diann-gui --init)
#
# 自托管交付只要求: install.packages() → library(diann.gui) → run_app()。
# 配置一律写在用户的 ~/.diann_gui/config.R, 不涉及 shell 脚本或系统级安装。
# ============================================================

# 自动探测分区 (sinfo); 没有 Slurm 时返回 character(0)
detect_slurm_partitions <- function() {
  out <- suppressWarnings(system("sinfo -h -o '%P' 2>/dev/null", intern = TRUE))
  if (!length(out)) return(character(0))
  p <- unique(trimws(sub("\\*$", "", out)))
  p[nzchar(p)]
}

# 在常见目录里非递归找 diann*.sif
detect_sif_dirs <- function() {
  cands <- c(file.path(path.expand("~"), "data"), "/share/app/tools/diann", "/opt", "/usr/local")
  cands <- unique(cands[dir.exists(cands)])
  if (!length(cands)) return(character(0))
  hit <- cands[vapply(cands, function(d) {
    length(list.files(d, pattern = "(?i)^diann.*\\.sif$")) > 0
  }, logical(1))]
  utils::head(hit, 3L)
}

# 纯函数: 把探测结果写回模板文本 (便于离线测试)
init_config_autofill <- function(txt, partitions = character(0),
                                 apptainer_dirs = character(0),
                                 default_apptainer = "",
                                 sif_dirs = character(0)) {
  rquote <- function(x) paste0('"', gsub('"', '\\\\"', x, fixed = TRUE), '"')
  rvec <- function(x) sprintf("c(%s)", paste(vapply(x, rquote, ""), collapse = ", "))
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  replace_or_insert <- function(lines, pattern, new_line, after_pattern = NULL) {
    idx <- grep(pattern, lines, perl = TRUE)
    if (length(idx)) {
      lines[idx[1]] <- new_line
      return(lines)
    }
    if (!is.null(after_pattern)) {
      j <- grep(after_pattern, lines, perl = TRUE)
      if (length(j)) {
        i <- j[1]
        return(append(lines, new_line, after = i))
      }
    }
    c(lines, new_line)
  }
  if (length(partitions)) {
    lines <- replace_or_insert(lines, "^#\\s*SLURM_PARTITIONS\\s*<-",
                               sprintf("SLURM_PARTITIONS <- %s", rvec(partitions)))
  }
  if (length(apptainer_dirs)) {
    lines <- replace_or_insert(lines, "^#\\s*APPTAINER_PATHS\\s*<-",
                               sprintf("APPTAINER_PATHS <- %s", rvec(unique(apptainer_dirs))))
    if (nzchar(default_apptainer)) {
      lines <- replace_or_insert(lines, "^#\\s*DEFAULT_APPTAINER\\s*<-",
                                 sprintf("DEFAULT_APPTAINER <- %s", rquote(default_apptainer)))
    }
  }
  if (length(sif_dirs)) {
    lines <- replace_or_insert(lines, "^#\\s*SIF_DIRS\\s*<-",
                               sprintf("SIF_DIRS <- %s", rvec(unique(sif_dirs))))
  }
  out <- paste(lines, collapse = "\n")
  if (endsWith(txt, "\n")) out <- paste0(out, "\n")
  out
}

#' 生成每用户配置文件
#'
#' 把包内模板 `inst/config/config.example.R` 复制到 `~/.diann_gui/config.R`，
#' 并把家目录占位符替换为真实路径。`auto = TRUE` 时还会探测 Slurm 分区、
#' apptainer 候选与常见 SIF 目录并写入。
#'
#' @param path 目标文件 (默认 `~/.diann_gui/config.R`)
#' @param overwrite 已存在时是否覆盖 (默认 FALSE, 只提示)
#' @param auto 是否自动填充探测结果 (默认交互式会话为 TRUE)
#' @param partitions/apptainer_dirs/default_apptainer/sif_dirs 显式注入探测结果 (测试用)
#' @return 配置文件路径 (invisible)
#' @export
init_config <- function(path = file.path(path.expand("~"), ".diann_gui", "config.R"),
                        overwrite = FALSE, auto = interactive(),
                        partitions = NULL, apptainer_dirs = NULL,
                        default_apptainer = NULL, sif_dirs = NULL) {
  tpl <- system.file("config", "config.example.R", package = "diann.gui")
  if (!nzchar(tpl) || !file.exists(tpl)) {
    alt <- file.path(getwd(), "inst", "config", "config.example.R")
    if (file.exists(alt)) tpl <- alt
  }
  if (!nzchar(tpl) || !file.exists(tpl)) stop("找不到配置模板 config.example.R (包安装不完整?)")
  if (file.exists(path) && !isTRUE(overwrite)) {
    message("配置已存在, 未改动: ", path, " (需要覆盖请传 overwrite = TRUE)")
    return(invisible(path))
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE, mode = "0700")

  txt <- paste(readLines(tpl, warn = FALSE), collapse = "\n")
  txt <- gsub("DIANN_GUI_USER_HOME", path.expand("~"), txt, fixed = TRUE)
  if (isTRUE(auto)) {
    if (is.null(partitions)) partitions <- tryCatch(detect_slurm_partitions(), error = function(e) character(0))
    if (is.null(sif_dirs)) sif_dirs <- tryCatch(detect_sif_dirs(), error = function(e) character(0))
    if (is.null(apptainer_dirs) || is.null(default_apptainer)) {
      cands <- tryCatch(apptainer_candidates(), error = function(e) NULL)
      if (!is.null(cands) && nrow(cands)) {
        if (is.null(apptainer_dirs)) apptainer_dirs <- unique(dirname(cands$path))
        if (is.null(default_apptainer)) default_apptainer <- apptainer_default(cands)
      } else {
        if (is.null(apptainer_dirs)) apptainer_dirs <- character(0)
        if (is.null(default_apptainer)) default_apptainer <- ""
      }
    }
    txt <- init_config_autofill(txt, partitions = partitions,
                                apptainer_dirs = apptainer_dirs,
                                default_apptainer = default_apptainer %||% "",
                                sif_dirs = sif_dirs)
  }
  writeLines(txt, path, useBytes = TRUE)
  try(Sys.chmod(path, "0600"), silent = TRUE)
  message("已生成配置: ", path)
  message("下一步: 按需编辑该文件 (SIF_DIRS / APPTAINER_PATHS / DATA_HOME), 然后运行 diann.gui::run_app()")
  invisible(path)
}
