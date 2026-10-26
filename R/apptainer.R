# ============================================================
# apptainer.R — apptainer/singularity 运行环境: 探测、版本识别、候选与校验
#
# 版本要求 (SIF 镜像): apptainer >= 1.0 或 singularity >= 3.0 —— 见下方 SIF_MIN_MAJOR。
#
# 设计 (v1.11):
#   * GUI 节点自动识别多个可执行文件, 逐个解析 --version, 像 sif 版本下拉一样列出候选;
#   * 识别不到时允许手动输入路径并「识别并验证」;
#   * 选定路径写入 sbatch 脚本作为首选, 计算节点不可见时按 候选目录 → PATH → module 回退;
#   * 探测结果按 path+mtime+size 缓存 24h, 避免每次启动都跑 --version (登录节点可能很慢);
#   * 本地 --version 失败只警告不阻断: 本集群登录节点没有 apptainer, 只有计算节点有。
# ============================================================

apptainer_run <- function(bin, args, timeout = 30) {
  # 经 bash 显式前置 apptainer 所在目录到 PATH: conda 安装的 apptainer 依赖同目录的
  # squashfuse 等辅助程序, 不前置 PATH 时 exec 会以 "squashfuse not found" 失败 (实测)
  payload <- sprintf('PATH=%s:"$PATH" exec %s %s', shQuote(dirname(bin)), shQuote(bin), paste(args, collapse = " "))
  # 非零退出是常态 (inspect/exec 失败、版本探测失败), 只需结果; 抑制 system2 的状态警告
  suppressWarnings(system2("bash", c("-c", shQuote(payload)), stdout = TRUE, stderr = TRUE, timeout = timeout))
}

# --version 文本 → list(kind, version); 解析不出返回 NULL
apptainer_parse_version <- function(txt) {
  s <- paste(as.character(txt %||% ""), collapse = "\n")
  if (!nzchar(trimws(s))) return(NULL)
  m <- regmatches(s, regexpr("(?i)(apptainer|singularity)\\s+(?:version\\s+)?v?([0-9]+(?:\\.[0-9]+)+)",
                             s, perl = TRUE))
  if (length(m)) {
    kind <- tolower(sub("(?i)^(apptainer|singularity).*$", "\\1", m, perl = TRUE))
    ver <- sub("^.*?v?([0-9]+(?:\\.[0-9]+)+)$", "\\1", m, perl = TRUE)
    return(list(kind = kind, version = ver))
  }
  toks <- regmatches(s, gregexpr("[0-9]+(?:\\.[0-9]+)+", s, perl = TRUE))[[1]]
  if (!length(toks)) return(NULL)
  list(kind = "", version = toks[length(toks)])
}

# ---- SIF 版本要求 ----------------------------------------------------------
# SIF (Singularity Image Format) 自 Singularity 3.0 (2018) 起才是镜像格式; 2.x 只认
# squashfs/ext3 的 .simg/.img, 拿到 .sif 时连镜像头都解析不了, 直接:
#   ERROR : Unknown image format/type: <file>
#   ABORT : Retval = 255
# (2.4.x 实测; 2.x 的 inspect 本身存在, 但只认自己的镜像格式)。apptainer 自 3.x 分支
# 而来, 1.x 起全程支持 SIF。故运行时下限: apptainer >= 1, singularity >= 3。
# 该下限被候选项标签、当前生效回显、快速/深度验证、提交前校验、doctor 共用。
SIF_MIN_MAJOR <- c(apptainer = 1L, singularity = 3L)

# 运行时类型: kind 优先; 解析不到 kind 时按文件名推断 (避免 bootstrap 脚本类包装被当成 apptainer)
apptainer_kind_of <- function(kind = "", path = "") {
  k <- tolower(trimws(as.character(kind %||% "")))
  if (length(k) == 1L && !is.na(k) && k %in% names(SIF_MIN_MAJOR)) return(k)
  b <- tolower(basename(as.character(path %||% "")))
  if (length(b) == 1L && !is.na(b) && grepl("singularity", b, fixed = TRUE)) "singularity" else "apptainer"
}

# 人类可读的版本要求 (UI 帮助行 / 验证结论 / 报错文案统一走这里)
sif_min_version_text <- function() {
  sprintf("apptainer ≥ %d.0 或 singularity ≥ %d.0",
          SIF_MIN_MAJOR[["apptainer"]], SIF_MIN_MAJOR[["singularity"]])
}

# 2.x 的确切症状 (放在结论行里, 用户搜得到原报错)
sif_2x_symptom <- function() {
  "singularity 2.x 只能读 squashfs/ext3 的 .simg, 读 .sif 会报 \"Unknown image format/type\" (ABORT: Retval = 255)"
}

# 该运行时能否读/运行 SIF: TRUE/FALSE; 版本解析不出时 NA (未知, 不作为拦截依据)
sif_capable <- function(kind = "", version = "") {
  v <- as.character(version %||% "")
  if (length(v) != 1L || is.na(v) || !nzchar(trimws(v))) return(NA)
  major <- suppressWarnings(as.integer(sub("^v?([0-9]+).*$", "\\1", trimws(v))))
  if (is.na(major)) return(NA)
  major >= SIF_MIN_MAJOR[[apptainer_kind_of(kind)]]
}

# 候选表补 sif_ok 列 (兼容旧缓存与外部构造的 data.frame, 如 doctor/测试注入)
apptainer_cands_sif <- function(cands) {
  if (is.null(cands) || !is.data.frame(cands) || !nrow(cands)) return(cands)
  if (is.null(cands$sif_ok)) {
    cands$sif_ok <- vapply(seq_len(nrow(cands)), function(i) {
      sif_capable(cands$kind[i], cands$version[i])
    }, logical(1))
  }
  cands
}

# 单个可执行文件校验 (可注入 runner 做离线测试)
apptainer_check <- function(path, runner = apptainer_run, timeout = 8) {
  res <- list(ok = FALSE, path = "", absolute = FALSE, exists = FALSE, executable = FALSE,
              kind = "", version = "", sif_ok = NA, sif_note = "", message = "", raw = character(0))
  p <- trimws(as.character(path %||% ""))
  if (!nzchar(p)) { res$message <- "路径为空"; return(res) }
  p <- path.expand(p)
  if (!startsWith(p, "/")) { res$message <- "必须是服务器绝对路径 (以 / 开头)"; return(res) }
  res$absolute <- TRUE
  if (dir.exists(p)) {
    cand <- file.path(p, c("apptainer", "singularity"))
    cand <- cand[file.exists(cand)]
    if (!length(cand)) { res$message <- sprintf("目录下没有 apptainer/singularity: %s", p); return(res) }
    p <- cand[1]
  }
  res$path <- p
  if (!file.exists(p)) { res$message <- sprintf("文件不存在: %s", p); return(res) }
  res$exists <- TRUE
  if (file.access(p, 1) != 0) { res$message <- sprintf("不可执行: %s", p); return(res) }
  res$executable <- TRUE
  out <- tryCatch(runner(p, "--version", timeout = timeout),
                  error = function(e) structure(paste("ERROR:", conditionMessage(e)), status = -1L))
  res$raw <- if (is.character(out)) out else character(0)
  v <- apptainer_parse_version(res$raw)
  if (!is.null(v)) {
    res$ok <- TRUE
    res$kind <- apptainer_kind_of(v$kind, p)   # 解析不出 kind 时按文件名判断, 以免 2.x 被当成支持 SIF
    res$version <- v$version
    res$message <- sprintf("%s %s", res$kind, v$version)
  } else {
    txt <- paste(res$raw, collapse = " ")
    res$message <- sprintf("无法执行 --version: %s", substr(trimws(gsub("\\s+", " ", txt)), 1, 200))
  }
  # 版本下限: 能跑 --version 不等于能读 SIF (2.x 就是这样), 单独留字段给 UI 标注与拦截
  if (isTRUE(res$ok)) {
    res$sif_ok <- sif_capable(res$kind, res$version)
    if (identical(res$sif_ok, FALSE)) {
      res$sif_note <- sprintf("不支持 SIF 镜像 (需要 %s): %s",
                              sif_min_version_text(),
                              if (identical(res$kind, "singularity")) sif_2x_symptom() else "版本过低")
    }
  }
  res
}

apptainer_cache_file <- function() {
  base <- file.path(path.expand("~"), ".diann_gui")
  if (!dir.exists(base)) dir.create(base, showWarnings = FALSE, recursive = TRUE)
  if (dir.exists(base) && file.access(base, 2) == 0) {
    return(file.path(base, "apptainer_probe.rds"))
  }
  file.path(tempdir(), "apptainer_probe.rds")
}

# 有界搜索目录: PATH 由 Sys.which 处理; 这里给目录扫描用
apptainer_search_dirs <- function(extra = cfg_get("APPTAINER_PATHS")) {
  dirs <- c(extra,
            "/usr/bin", "/usr/local/bin", "/opt/apptainer/bin", "/usr/local/apptainer/bin",
            Sys.glob("/opt/apptainer/*/bin"),
            path.expand(c("~/.local/bin", "~/bin")),
            Sys.glob(path.expand(c("~/miniconda3/envs/*/bin", "~/anaconda3/envs/*/bin",
                                   "~/miniforge3/envs/*/bin", "~/.conda/envs/*/bin"))))
  dirs <- dirs[!is.na(dirs) & nzchar(dirs)]
  unique(dirs)
}

# 文件系统发现 (无子进程)
apptainer_discover <- function(extra_dirs = cfg_get("APPTAINER_PATHS"), max_candidates = 20L,
                               search_dirs = NULL) {
  found <- list()
  add <- function(p, source) {
    if (length(found) >= max_candidates) return(invisible(NULL))
    if (!file.exists(p) || dir.exists(p)) return(invisible(NULL))
    if (file.access(p, 1) != 0) return(invisible(NULL))
    real <- normalizePath(p, mustWork = FALSE)
    if (any(vapply(found, function(x) identical(x$real, real), logical(1)))) return(invisible(NULL))
    found[[length(found) + 1L]] <<- list(
      path = p,
      kind = if (grepl("singularity", basename(p), fixed = TRUE)) "singularity" else "apptainer",
      source = source, real = real)
  }
  for (n in c("apptainer", "singularity")) {
    w <- unname(Sys.which(n))
    if (nzchar(w)) add(w, "PATH")
  }
  dirs <- if (is.null(search_dirs)) apptainer_search_dirs(extra_dirs) else search_dirs
  for (d in dirs) {
    src <- if (length(extra_dirs) && d %in% extra_dirs) "APPTAINER_PATHS" else "common"
    for (n in c("apptainer", "singularity")) add(file.path(d, n), src)
  }
  empty <- data.frame(path = character(0), kind = character(0), source = character(0),
                      mtime = numeric(0), size = numeric(0), stringsAsFactors = FALSE)
  if (!length(found)) return(empty)
  df <- data.frame(
    path = vapply(found, function(x) x$path, ""),
    kind = vapply(found, function(x) x$kind, ""),
    source = vapply(found, function(x) x$source, ""),
    stringsAsFactors = FALSE)
  fi <- file.info(df$path)
  df$mtime <- as.numeric(fi$mtime)
  df$size <- as.numeric(fi$size)
  df
}

# 候选 + 版本 (带缓存: path+mtime+size 未变且未过期则直接复用)
apptainer_candidates <- function(refresh = FALSE, ttl = 86400,
                                 cache_file = apptainer_cache_file(),
                                 runner = apptainer_run, extra_dirs = cfg_get("APPTAINER_PATHS"),
                                 search_dirs = NULL, now = as.numeric(Sys.time())) {
  disc <- apptainer_discover(extra_dirs, search_dirs = search_dirs)
  key <- function(df) if (!nrow(df)) "" else paste(df$path, df$mtime, df$size, sep = "|")
  cache <- NULL
  if (!refresh && file.exists(cache_file)) {
    cache <- tryCatch(readRDS(cache_file), error = function(e) NULL)
  }
  if (!is.null(cache) && is.data.frame(cache$cands) && !is.null(cache$checked_at) &&
      identical(key(cache$disc), key(disc)) && (now - cache$checked_at) < ttl) {
    return(apptainer_cands_sif(cache$cands))   # 旧缓存没有 sif_ok 列 -> 现算
  }
  if (!nrow(disc)) {
    cands <- data.frame(path = character(0), kind = character(0), source = character(0),
                        version = character(0), ok = logical(0), sif_ok = logical(0),
                        checked_at = numeric(0), stringsAsFactors = FALSE)
  } else {
    checks <- lapply(disc$path, function(p) apptainer_check(p, runner = runner))
    cands <- data.frame(
      path = disc$path, kind = disc$kind, source = disc$source,
      version = vapply(checks, function(x) if (isTRUE(x$ok)) as.character(x$version) else NA_character_, ""),
      ok = vapply(checks, function(x) isTRUE(x$ok), logical(1)),
      sif_ok = vapply(checks, function(x) isTRUE(x$sif_ok), logical(1)),
      checked_at = now, stringsAsFactors = FALSE)
    # 排序: apptainer 优先 → 可执行优先 → 版本降序 → 路径
    # (版本解析失败时 sif_ok 记为 FALSE, 但 !ok 已把它排在后面, 不影响这里的次序)
    vkey <- vapply(cands$version, function(v) {
      if (is.na(v) || !nzchar(v)) return(-1)
      p <- suppressWarnings(as.integer(strsplit(v, ".", fixed = TRUE)[[1]]))
      p <- p[!is.na(p)]
      if (!length(p)) return(-1)
      k <- seq_len(min(3L, length(p)))
      sum(p[k] * c(1e6, 1e3, 1)[k])
    }, numeric(1))
    cands <- cands[order(cands$kind != "apptainer", !cands$ok, -vkey, cands$path), , drop = FALSE]
    rownames(cands) <- NULL
  }
  tryCatch(saveRDS(list(cands = cands, disc = disc, checked_at = now), cache_file),
           error = function(e) NULL)
  cands
}

# 下拉标签: 把"SIF 不支持"直接写进选项名, 不用点开验证就能看到
apptainer_choices <- function(cands) {
  if (is.null(cands) || !nrow(cands)) return(character(0))
  cands <- apptainer_cands_sif(cands)
  ver <- ifelse(cands$ok & !is.na(cands$version), cands$version, "(版本未知)")
  no_sif <- !is.na(cands$sif_ok) & !cands$sif_ok & cands$ok
  labels <- sprintf("%s %s%s · %s", cands$kind, ver,
                    ifelse(no_sif, " ⚠ 不支持 SIF", ""), cands$path)
  stats::setNames(cands$path, labels)
}

apptainer_default <- function(cands) {
  if (is.null(cands) || !nrow(cands)) return("")
  cands <- apptainer_cands_sif(cands)
  d <- cfg_get("DEFAULT_APPTAINER") %||% ""
  if (nzchar(d)) {
    np <- normalizePath(cands$path, mustWork = FALSE)
    hit <- cands$path[np == normalizePath(path.expand(d), mustWork = FALSE)]
    if (length(hit)) return(hit[1])
  }
  # 默认优先"可执行且能读 SIF"的候选, 免得下拉默认值就是个跑不起来的 2.x
  good <- cands[cands$ok & !is.na(cands$sif_ok) & cands$sif_ok, , drop = FALSE]
  if (nrow(good)) return(good$path[1])
  ok <- cands[cands$ok, , drop = FALSE]
  if (nrow(ok)) return(ok$path[1])
  cands$path[1]
}

# module 回退可用性 (自检面板/doctor 用)
apptainer_module_probe <- function() {
  mod <- cfg_get("APPTAINER_MODULE_FALLBACK") %||% ""
  if (!nzchar(mod)) return(NULL)
  tryCatch({
    pl <- sprintf(paste0('source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null; ',
                         'module load %s 2>/dev/null && command -v apptainer'), mod)
    out <- suppressWarnings(system2("bash", c("-c", shQuote(pl)), stdout = TRUE, stderr = TRUE, timeout = 15))
    list(ok = is.character(out) && any(nzchar(out)),
         path = if (is.character(out)) utils::tail(out[nzchar(out)], 1) else "")
  }, error = function(e) list(ok = FALSE, path = ""))
}
