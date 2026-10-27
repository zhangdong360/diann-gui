# ============================================================
# sif.R — DIA-NN 镜像扫描与容器版本识别 (v1.13)
#
# v1.12 及以前按文件名解析版本: 不匹配 ^diann.*\.sif$ 的镜像 (image.sif、
# diann_latest.sif…) 直接不可见, 版本也取自文件名 (可能与镜像内容不一致,
# 是"放了镜像却看不到"的主因)。v1.13 起文件名完全无关:
#   - scan_sif_images(): 递归扫描 SIF_DIRS 下所有 *.sif, 只按路径去重;
#   - 版本只来自容器内 `diann-linux --version` (sif_identify), 结果缓存到
#     ~/.diann_gui/sif_probe.rds (size+mtime 变化即失效); 启动不跑容器;
#   - 排序/默认选中禁止字符串比较、也禁止 as.numeric(numeric_version)
#     (2.10.0 会塌缩成 2.1 排到 2.9 之后 — v1.11 B9 事故类别), 必须走
#     numeric_version / sif_ver_sort_string()。
# ============================================================

empty_sif_scan <- function() data.frame(path = character(), name = character(),
                                        size = numeric(), mtime = numeric(),
                                        stringsAsFactors = FALSE)

# 递归扫描 dirs 下所有 *.sif (大小写不敏感); 返回 data.frame(path, name, size, mtime)。
# 不解析文件名、不按版本去重, 只按规范化路径去重 (符号链接指向同一文件只留一个)。
scan_sif_images <- function(dirs, pattern = "(?i)\\.sif$") {
  dirs <- dirs[!is.na(dirs) & nzchar(dirs)]
  if (!length(dirs)) return(empty_sif_scan())
  paths <- unlist(lapply(dirs, function(d) {
    if (dir.exists(d)) {
      list.files(d, pattern = pattern, full.names = TRUE, recursive = TRUE)
    } else character(0)
  }), use.names = FALSE)
  paths <- unique(normalizePath(paths, mustWork = FALSE))
  if (!length(paths)) return(empty_sif_scan())
  fi <- file.info(paths)
  data.frame(
    path = unname(paths), name = basename(paths),
    size = unname(ifelse(is.finite(fi$size), fi$size, NA_real_)),
    mtime = unname(ifelse(is.finite(as.numeric(fi$mtime)), as.numeric(fi$mtime), NA_real_)),
    stringsAsFactors = FALSE
  )
}

# "DIA-NN 2.7.0 Academia, build …" -> "2.7.0"; 识别不到返回 ""
# 输出里可能有多个 DIA-NN 字样 (如回显的命令行), 优先取行首匹配, 无行首匹配才取第一个
parse_diann_version <- function(txt) {
  txt <- paste(as.character(txt %||% ""), collapse = "\n")
  pat <- "(?i)DIA-NN[[:space:]]+[0-9]+(?:\\.[0-9]+)+"
  line_starts <- regmatches(txt, gregexpr(paste0("(?m)^[[:space:]]*", pat), txt, perl = TRUE))[[1]]
  hit <- if (length(line_starts)) line_starts else
    regmatches(txt, gregexpr(pat, txt, perl = TRUE))[[1]]
  if (!length(hit)) return("")
  trimws(sub("(?i)^\\s*DIA-NN[[:space:]]+", "", hit[1]))
}

# 容器识别: 静态检查 → 运行时可用 → inspect (信息) → exec diann-linux --version。
# 返回 list(ok, version, stage, message, inspect, raw_version_lines, reason):
#   ok=TRUE 当且仅当解析到版本; reason ∈ {"missing","unreadable","not_sif",
#   "no_apptainer","timeout","no_diann_linux","no_version",""}
# runner 可注入 (测试不依赖真实容器)。reason="no_apptainer" 表示"GUI 节点暂时
# 识别不了"而非镜像问题 — 缓存层对它不落失败记录, 之后有运行时可自动重试。
sif_identify <- function(sif, apptainer_bin, timeout = 60, runner = apptainer_run) {
  sif <- trimws(as.character(sif %||% ""))
  ap <- trimws(as.character(apptainer_bin %||% ""))
  fail <- function(stage, reason, message, inspect = "", raw = character(0)) {
    list(ok = FALSE, version = "", stage = stage, message = message,
         inspect = inspect, raw_version_lines = raw, reason = reason)
  }
  lc <- sif_check_local(sif)
  if (!lc$exists) return(fail("static", "missing", sprintf("镜像不存在: %s", sif)))
  if (!isTRUE(lc$readable)) {
    return(fail("static", "unreadable",
                sprintf("GUI 运行身份 (%s) 无权读取该镜像", Sys.info()[["user"]])))
  }
  if (!isTRUE(lc$sif_magic)) {
    return(fail("static", "not_sif",
                "SIF 魔数校验失败 — 不是有效的 SIF 镜像 (可能损坏或下载截断)"))
  }
  if (!nzchar(ap)) {
    return(fail("runtime", "no_apptainer",
                paste0("GUI 节点无可用 apptainer/singularity, 版本未识别 (不影响提交; ",
                       "作业脚本在计算节点自行回退查找运行时)")))
  }
  if (!file.exists(ap) || file.access(ap, 1) != 0) {
    return(fail("runtime", "no_apptainer",
                sprintf("所选 apptainer 在 GUI 节点不可执行: %s (计算节点可见时作业仍可运行)", ap)))
  }
  ins <- tryCatch(suppressWarnings(runner(ap, c("inspect", shQuote(sif)), timeout = min(timeout, 15L))),
                  error = function(e) paste("inspect 出错:", conditionMessage(e)))
  ins_txt <- if (is.character(ins)) paste(ins, collapse = "\n") else ""
  exe <- tryCatch(suppressWarnings(runner(ap, c("exec", shQuote(sif), "diann-linux", "--version"),
                                          timeout = timeout)),
                  error = function(e) paste("exec 出错:", conditionMessage(e)))
  exe_txt <- if (is.character(exe)) paste(exe, collapse = "\n") else ""
  raw <- if (is.character(exe)) exe[nzchar(exe)] else character(0)
  # system2(timeout=) 超时返回 character(0) + attr(,"status")==124, 没有 "timed out" 文本;
  # 必须按状态属性判定, 否则超时会被误归为 no_version 且落失败缓存 (不再自动重试)
  tstat <- if (is.character(exe) && !length(exe)) attr(exe, "status") else NULL
  timed_out <- (!is.null(tstat) && all(as.integer(tstat) == 124L)) ||
    grepl("timed out", exe_txt, fixed = TRUE)
  if (timed_out) {
    return(fail("version", "timeout",
                sprintf("容器内执行超时 (%ss); 若计算节点正常, 可稍后重试 (超时不落缓存, 会自动重试)", timeout),
                inspect = ins_txt, raw = raw))
  }
  ver <- parse_diann_version(exe_txt)
  if (nzchar(ver)) {
    msg <- sprintf("容器内 DIA-NN 可执行, 实际版本: %s", ver)
    if (grepl("org.label-schema.usage.singularity.deffile.from:", ins_txt)) {
      from <- trimws(sub(".*org.label-schema.usage.singularity.deffile.from:[[:space:]]*([^\n]+).*",
                         "\\1", ins_txt))
      if (nzchar(from) && from != ins_txt) msg <- sprintf("%s (镜像基础: %s)", msg, from)
    }
    return(list(ok = TRUE, version = ver, stage = "version", message = msg,
                inspect = ins_txt, raw_version_lines = raw, reason = ""))
  }
  tl <- if (length(raw)) tail(raw, 1) else "(无输出)"
  tl <- gsub("\r", " ", gsub("\033\\[[0-9;]*[A-Za-z]", "", tl))
  if (grepl("(?i)diann-linux.*(not found|no such file|exec.*failed)", exe_txt, perl = TRUE)) {
    return(fail("version", "no_diann_linux",
                paste0("容器内找不到 diann-linux — 镜像未把 DIA-NN 目录加入 PATH ",
                       "(构建说明见 README「构建 DIA-NN 容器镜像」章节)"),
                inspect = ins_txt, raw = raw))
  }
  fail("version", "no_version",
       sprintf("容器已启动但未解析到 DIA-NN 版本: %s", substr(trimws(tl), 1, 160)),
       inspect = ins_txt, raw = raw)
}

# ---------- 识别缓存 (~/.diann_gui/sif_probe.rds; 不可写回退 tempdir) ----------

sif_probe_file <- function() {
  d <- file.path(path.expand("~"), ".diann_gui")
  ok <- dir.exists(d) ||
    suppressWarnings(dir.create(d, showWarnings = FALSE, recursive = TRUE, mode = "0700"))
  if (isTRUE(ok) && file.access(d, 2) == 0) file.path(d, "sif_probe.rds")
  else file.path(tempdir(), sprintf("diann_gui_sif_probe_%s.rds", Sys.getpid()))
}

sif_probe_load <- function(file = sif_probe_file()) {
  if (!nzchar(file) || !file.exists(file)) return(list(entries = list(), version = 1L))
  x <- tryCatch(suppressWarnings(readRDS(file)), error = function(e) NULL)
  if (is.list(x) && is.list(x$entries)) x else list(entries = list(), version = 1L)
}

sif_probe_save <- function(probe, file = sif_probe_file()) {
  tmp <- sprintf("%s.tmp.%d", file, Sys.getpid())
  ok <- tryCatch({ saveRDS(probe, tmp); file.rename(tmp, file) },
                 error = function(e) FALSE,
                 warning = function(w) FALSE)
  if (!isTRUE(ok)) try(unlink(tmp), silent = TRUE)
  invisible(isTRUE(ok))
}

# 命中要求 path 且 size+mtime 都一致 (文件被覆盖/重建后缓存自动失效)
sif_probe_lookup <- function(probe, path, size = NULL, mtime = NULL) {
  e <- probe$entries[[trimws(as.character(path %||% ""))]]
  if (is.null(e) || !is.list(e)) return(NULL)
  if (!is.null(size) && !identical(as.numeric(e$size %||% NA_real_), as.numeric(size))) return(NULL)
  if (!is.null(mtime) && !identical(as.numeric(e$mtime %||% NA_real_), as.numeric(mtime))) return(NULL)
  e
}

sif_probe_record <- function(probe, path, size, mtime, ver = "", ok = FALSE,
                             message = "", reason = "") {
  # 瞬时原因不落缓存 (否则失败记录会挡住之后的自动重试):
  #   no_apptainer = GUI 节点暂时没有运行时; timeout = 容器执行超时, 镜像本身可能没问题
  if (identical(reason, "no_apptainer") || identical(reason, "timeout")) return(invisible(probe))
  probe$entries[[trimws(as.character(path))]] <-
    list(size = as.numeric(size), mtime = as.numeric(mtime),
         ver = as.character(ver)[1], ok = isTRUE(ok),
         message = as.character(message)[1], reason = as.character(reason)[1],
         checked_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"))
  invisible(probe)
}

# ---------- 合并 / 排序 / 标签 ----------

# 批量排序键: 先经 as.numeric_version 解析 (非法 -> NA -> "~", 排在已识别之后),
# 每个数字分量按 %012d 定宽拼接 — 字典序即版本序, 且分量再大也不反序
# (纯字符串零填充在分量 >=100000 时会排反)。同样严禁 as.numeric(numeric_version):
# "2.10.0" 会塌缩成 2.1, 排到 2.9 之后 (v1.11 B9 事故类别)。
sif_ver_sort_string <- function(ver) {
  vapply(ver, function(x) {
    x <- trimws(as.character(x %||% ""))
    if (is.na(x) || !nzchar(x)) return("~")
    nv <- tryCatch(suppressWarnings(as.numeric_version(x)), error = function(e) NULL)
    if (is.null(nv) || length(nv) != 1 || is.na(nv)) return("~")
    comps <- unlist(as.vector(nv), use.names = FALSE)
    if (!length(comps) || !all(is.finite(comps))) return("~")
    paste(sprintf("%012d", as.integer(comps)), collapse = ".")
  }, character(1), USE.NAMES = FALSE)
}

# 标量两两比较用的版本键: numeric_version 或 NA (非法)。同样禁止 as.numeric()。
# 注意 as.numeric_version() 对非法串抛 error (不是 warning), 必须 tryCatch。
sif_version_key <- function(ver) {
  v <- trimws(as.character(ver %||% ""))
  if (!nzchar(v) || is.na(v)) return(NA)
  out <- tryCatch(suppressWarnings(as.numeric_version(v)), error = function(e) NULL)
  if (is.null(out) || length(out) != 1 || is.na(out)) NA else out
}

# 展示顺序: 已识别按数值版本降序 (同版本按路径升序), 未识别排在最后 (按路径)。
# 不能把两组揉进同一 key 降序排 — "~" (未知) 字典序最大, 降序会被排到最前。
sif_display_order <- function(df) {
  n <- nrow(df)
  if (!n) return(integer(0))
  ver <- if (is.null(df$ver)) rep(NA_character_, n) else df$ver
  vfd <- if (is.null(df$verified)) rep(FALSE, n) else df$verified
  idx_id <- which(vfd); idx_un <- which(!vfd)
  ord_id <- if (length(idx_id)) {
    idx_id[order(sif_ver_sort_string(ver[idx_id]), df$path[idx_id],
                 decreasing = c(TRUE, FALSE), method = "radix")]
  } else integer(0)
  ord_un <- if (length(idx_un)) idx_un[order(df$path[idx_un], method = "radix")] else integer(0)
  c(ord_id, ord_un)
}

# scan(全部镜像) + probe(版本缓存) -> data.frame(path,name,size,mtime,ver,verified,probe_message)
# 已按 sif_display_order 排序; verified=TRUE 的行 ver 一定是合法版本字符串。
sif_merge_probe <- function(scan, probe) {
  if (!nrow(scan)) {
    return(cbind(empty_sif_scan(),
                 data.frame(ver = character(), verified = logical(),
                            probe_message = character(), stringsAsFactors = FALSE)))
  }
  ver <- rep(NA_character_, nrow(scan))
  verified <- rep(FALSE, nrow(scan))
  pmsg <- rep("", nrow(scan))
  for (i in seq_len(nrow(scan))) {
    e <- sif_probe_lookup(probe, scan$path[i], scan$size[i], scan$mtime[i])
    if (!is.null(e)) {
      pmsg[i] <- as.character(e$message %||% "")
      if (isTRUE(e$ok) && nzchar(e$ver %||% "")) { ver[i] <- e$ver; verified[i] <- TRUE }
    }
  }
  df <- cbind(scan, data.frame(ver = ver, verified = verified, probe_message = pmsg,
                               stringsAsFactors = FALSE))
  df[sif_display_order(df), , drop = FALSE]
}

# 命名向量: 标签 -> path。"v2.7.0 · /path" / "未识别 · /path"
sif_choice_labels <- function(df) {
  if (!nrow(df)) return(character(0))
  d <- df[sif_display_order(df), , drop = FALSE]
  vs <- if (is.null(d$verified)) rep(FALSE, nrow(d)) else d$verified
  lab <- ifelse(vs, sprintf("v%s · %s", d$ver, d$path), sprintf("未识别 · %s", d$path))
  stats::setNames(d$path, lab)
}

# 默认选中 (df 须已按 sif_display_order 排序): DEFAULT_SIF 命中优先;
# 否则首个已识别 (= 数值版本最高); 再否则首个路径。
sif_default_index <- function(df, default_path = NULL) {
  if (!nrow(df)) return(NA_integer_)
  dp <- trimws(as.character(default_path %||% ""))
  if (nzchar(dp)) {
    hit <- which(df$path == dp)
    if (length(hit)) return(as.integer(hit[1]))
  }
  hit <- which(df$verified)
  if (length(hit)) return(as.integer(hit[1]))
  1L
}

# 提交用版本字符串: 读缓存 (size+mtime 命中且 ok); 未识别返回 ""
sif_version_of <- function(path, probe = NULL) {
  p <- trimws(as.character(path %||% ""))
  if (!nzchar(p) || !file.exists(p)) return("")
  if (is.null(probe)) probe <- sif_probe_load()
  fi <- file.info(p)
  e <- sif_probe_lookup(probe, p, unname(fi$size), as.numeric(fi$mtime))
  if (is.null(e) || !isTRUE(e$ok)) "" else as.character(e$ver)
}
