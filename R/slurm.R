# ============================================================
# slurm.R — Slurm 查询收敛 (一次 squeue + 一次 sacct, 短时缓存)
#
# 旧实现每 10–15 s、每条待处理记录各跑一次 squeue/sacct: 20 条记录就是
# 40+ 个子进程, 中央部署下会成为明显的负载。这里统一成"每次刷新只查一次"。
# ============================================================

slurm_cache <- new.env(parent = emptyenv())

# 返回 list(lines = 原始行, squeue_map = jobid -> 状态, sacct_map = jobid -> 状态, at)
slurm_snapshot <- function(user = NULL, max_age = 20, refresh = FALSE,
                           squeue_fun = NULL, sacct_fun = NULL) {
  now <- as.numeric(Sys.time())
  if (is.null(user) || !nzchar(user)) user <- Sys.getenv("USER")
  key <- user
  cached <- if (exists(key, envir = slurm_cache, inherits = FALSE)) get(key, envir = slurm_cache) else NULL
  if (!refresh && !is.null(cached) && now - cached$at < max_age) return(cached)

  if (is.null(squeue_fun)) {
    fmt <- "%.10i|%j|%T|%M|%R"
    squeue_fun <- function(u) suppressWarnings(system(
      sprintf("squeue -h -u %s -o %s 2>/dev/null", shQuote(u), shQuote(fmt)), intern = TRUE))
  }
  if (is.null(sacct_fun)) {
    since <- format(Sys.Date() - 1, "%Y-%m-%d")
    sacct_fun <- function(u) suppressWarnings(system(
      sprintf("sacct -u %s -S %s -X -n --parsable2 -o jobid,jobname,state,elapsed,end 2>/dev/null",
              shQuote(u), since), intern = TRUE))
  }
  sq <- tryCatch(squeue_fun(user), error = function(e) character(0))
  sa <- tryCatch(sacct_fun(user), error = function(e) character(0))
  sq <- as.character(sq); sq <- sq[nzchar(trimws(sq))]
  sa <- as.character(sa); sa <- sa[nzchar(trimws(sa))]

  parse_map <- function(lines, id_col = 1L, st_col) {
    out <- list()
    for (l in lines) {
      f <- strsplit(l, "|", fixed = TRUE)[[1]]
      if (length(f) < st_col) next
      id <- trimws(f[id_col])
      if (nzchar(id) && is.null(out[[id]])) out[[id]] <- trimws(f[st_col])
    }
    out
  }
  data <- list(lines = sq, sacct_lines = sa,
               squeue_map = parse_map(sq, 1L, 3L),   # id|name|state|time|reason
               sacct_map = parse_map(sa, 1L, 3L),    # id|name|state|elapsed|end
               at = now)
  assign(key, data, envir = slurm_cache)
  data
}

# 把快照包装成 diann_job_status 需要的两个函数 (避免每条记录再起子进程)
slurm_snapshot_fns <- function(snap) {
  sq <- snap$squeue_map %||% list()
  sa <- snap$sacct_map %||% list()
  list(
    squeue_fn = function(id) {
      st <- sq[[as.character(id)]]
      if (is.null(st)) character(0) else st
    },
    sacct_fn = function(id) {
      st <- sa[[as.character(id)]]
      if (is.null(st)) character(0) else paste(as.character(id), st, sep = "|")
    }
  )
}

# watcher 用: 一次 squeue -u 得到 jobid -> 状态; 不再逐条 squeue -j
slurm_queue_states <- function(user = NULL, squeue_fun = NULL) {
  slurm_snapshot(user = user, squeue_fun = squeue_fun)$squeue_map
}
