# ============================================================
# diann_core.R — GUI 纯函数核心
#
# 不依赖 shiny 与集群环境 (仅 base R + 运行期引用的站点配置常量:
# 站点常量 (BASE_VOLUMES / CON_FASTA / APPTAINER_* / BIND_PATHS) 经
# cfg_get() 从包配置环境读取 (R/config.R 的 diann_load_config 装入)。
# 被 app.R source; tests/testthat/helper.R 直接 source 本文件做离线测试。
# ============================================================

# 路径范围守卫: 命令导入等自由输入的路径必须位于 BASE_VOLUMES 根目录之下
# normalizePath 对不存在的路径不折叠 "..", 先做词法折叠防止 /user/../../x 绕过前缀检查
collapse_dots <- function(p) {
  vapply(p, function(x) {
    parts <- strsplit(x, "/", fixed = TRUE)[[1]]
    out <- character(0)
    for (pt in parts[nzchar(parts) & parts != "."]) {
      if (pt == ".." && length(out)) out <- out[-length(out)] else out <- c(out, pt)
    }
    paste0(if (startsWith(x, "/")) "/" else "", paste(out, collapse = "/"))
  }, character(1), USE.NAMES = FALSE)
}
path_in_scope <- function(p) {
  out <- rep(FALSE, length(p))
  keep <- nzchar(p)
  if (!any(keep)) return(out)
  np <- normalizePath(collapse_dots(p[keep]), mustWork = FALSE)
  roots <- normalizePath(unname(cfg_get("BASE_VOLUMES")), mustWork = FALSE)
  out[keep] <- vapply(np, function(x) any(x == roots | startsWith(x, paste0(roots, "/"))), logical(1))
  out
}
nz_str <- function(x) !is.null(x) && length(x) > 0 && !any(is.na(x)) && all(nzchar(trimws(as.character(x))))

# 容器可见性: apptainer 默认只绑 $HOME / cwd / /tmp, 其它路径必须显式 --bind。
# 返回不在任何 root 之下的路径 (用于提交前警告; v1.4 事故类别)。
container_visible <- function(paths, roots) {
  paths <- as.character(paths %||% character(0))
  paths <- paths[!is.na(paths) & nzchar(paths)]
  roots <- as.character(roots %||% character(0))
  roots <- roots[!is.na(roots) & nzchar(roots)]
  if (!length(paths)) return(character(0))
  if (!length(roots)) return(paths)
  rp <- normalizePath(collapse_dots(roots), mustWork = FALSE)
  np <- normalizePath(collapse_dots(paths), mustWork = FALSE)
  ok <- vapply(np, function(p) any(p == rp | startsWith(p, paste0(rp, "/"))), logical(1))
  paths[!ok]
}
`%||%` <- function(a, b) if (is.null(a)) b else a

# 任务名同时用于 #SBATCH -J 与脚本文件名 diann_<时间戳>_<任务名>.sh。
# 文件名不能含路径分隔符/换行（曾致 file.path 报错或写出 diann_gui_scripts 之外）;
# 允许中文: 用户习惯用中文任务名。
safe_job_name <- function(x, max_len = 64L) {
  nm <- gsub("[\r\n\t]+", " ", trimws(as.character(x %||% "")))
  nm <- gsub("[/\\\\]", "-", nm)
  nm <- gsub("^\\.+", "", trimws(nm))
  nm <- trimws(nm)
  if (!nzchar(nm)) nm <- "DIANN_Task"
  if (nchar(nm, type = "chars") > max_len) nm <- substr(nm, 1L, max_len)
  nm
}
flag_arg <- function(on, f) if (identical(on, TRUE)) f else NULL
num_arg <- function(v, f) if (!is.null(v) && length(v) == 1 && !is.na(v)) c(f, format(v, trim = TRUE, scientific = FALSE)) else NULL
pos_arg <- function(v, f) if (!is.null(v) && length(v) == 1 && !is.na(v) && v > 0) c(f, format(v, trim = TRUE, scientific = FALSE)) else NULL
str_arg <- function(v, f) if (nz_str(v)) c(f, shQuote(trimws(v))) else NULL

# ---- sif 镜像静态校验 (纯本地检查, 不调 apptainer; GUI 提交前校验与「验证镜像」按钮共用) ----
# SIF 格式: 前 32 字节是 "#!/usr/bin/env run-singularity" 引导头, 偏移 32 处为 9 字节魔数 "SIF_MAGIC"
sif_magic_ok <- function(path) {
  ok <- tryCatch({
    con <- file(path, "rb"); on.exit(close(con))
    seek(con, 32)
    identical(readBin(con, "raw", n = 9), charToRaw("SIF_MAGIC"))
  }, error = function(e) FALSE)
  isTRUE(ok)
}
# 返回 list(exists, size_bytes, readable, sif_magic):
# readable/sif_magic 为 NA 表示因前置条件缺失而未检查。
# v1.13: 删除 ver_from_name — 版本不再从文件名提取, 只来自容器识别 (见 R/sif.R)。
sif_check_local <- function(path) {
  p <- trimws(as.character(path %||% ""))
  if (length(p) != 1 || !nzchar(p)) {
    return(list(exists = FALSE, size_bytes = NA_real_, readable = FALSE, sif_magic = FALSE))
  }
  ex <- file.exists(p)
  res <- list(exists = ex, size_bytes = NA_real_, readable = NA, sif_magic = NA)
  if (!ex) return(res)
  fi <- file.info(p)
  res$size_bytes <- if (is.finite(fi$size)) fi$size else NA_real_
  res$readable <- unname(file.access(p, 4)[1]) == 0
  if (isTRUE(res$readable)) res$sif_magic <- sif_magic_ok(p)
  res
}

build_diann_chunks <- function(p) {
  ch <- character(0)
  add <- function(x) if (!is.null(x)) ch <<- c(ch, paste(x, collapse = " "))

  # --- RAW→DIA 仅转换模式: 最小命令, 忽略分析参数 ---
  # 注意: 不用 --out-dir (DIA-NN 会以反斜杠拼接生成畸形文件名), .dia 默认写在 RAW 文件所在目录
  if (isTRUE(p$convert_only)) {
    if (identical(p$raw_mode, "dir")) add(str_arg(p$raw_dir, "--dir-all"))
    else if (length(p$raws)) ch <- c(ch, paste0("--f ", shQuote(p$raws)))
    add(flag_arg(TRUE, "--convert"))
    ch <- c(ch, paste0("--threads ", as.integer(p$threads)), paste0("--verbose ", p$verbose))
    if (nz_str(p$extra)) ch <- c(ch, trimws(gsub("\\s*\\n\\s*", " ", p$extra)))
    return(ch)
  }

  # --- 输入文件 ---
  # 以"实际提供了什么"为准, 不只信 raw_mode: 导入的 RAW 覆盖层与目录选择器可能交叉存在,
  # 旧实现只看 raw_mode 会在 dir 模式下静默丢掉导入的 raws (命令一个输入都没有)。
  if (identical(p$raw_mode, "dir") && nz_str(p$raw_dir)) {
    add(str_arg(p$raw_dir, "--dir-all"))
  } else if (length(p$raws)) {
    ch <- c(ch, paste0("--f ", shQuote(p$raws)))
  } else if (nz_str(p$raw_dir)) {
    add(str_arg(p$raw_dir, "--dir-all"))  # files 模式但只有目录: 不让输入凭空消失
  }
  add(str_arg(p$lib, "--lib"))
  for (f in p$fastas) ch <- c(ch, paste0("--fasta ", shQuote(f)))
  if (isTRUE(p$cont_exclude) && nz_str(cfg_get("CON_FASTA"))) ch <- c(ch, paste0("--fasta ", shQuote(cfg_get("CON_FASTA"))))
  add(flag_arg(p$cont_exclude, paste0("--cont-quant-exclude ",
                                      shQuote(if (nz_str(p$cont_tag)) trimws(p$cont_tag) else "cRAP-"))))
  add(str_arg(p$ref, "--ref"))
  add(str_arg(p$temp, "--temp"))

  # --- 常规 ---
  ch <- c(ch, paste0("--threads ", as.integer(p$threads)))
  ch <- c(ch, paste0("--verbose ", p$verbose))
  add(str_arg(p$out_file, "--out"))
  add(num_arg(p$qvalue, "--qvalue"))
  add(flag_arg(p$reanalyse, "--reanalyse"))
  add(flag_arg(p$rt_prof, "--rt-profiling"))
  add(flag_arg(p$peptidoforms, "--peptidoforms"))
  add(flag_arg(p$proteoforms, "--proteoforms"))
  add(flag_arg(p$matrices, "--matrices"))
  add(flag_arg(p$indiv_reports, "--individual-reports"))
  add(flag_arg(p$unimod4, "--unimod4"))

  # --- 质量与提取（留空 = DIA-NN 自动） ---
  add(num_arg(p$mass_acc, "--mass-acc"))
  add(num_arg(p$mass_acc_ms1, "--mass-acc-ms1"))
  add(num_arg(p$window, "--window"))
  add(num_arg(p$min_peak, "--min-peak"))
  add(num_arg(p$rt_window, "--rt-window"))
  add(num_arg(p$im_window, "--im-window"))
  add(num_arg(p$quant_qvalue, "--quant-qvalue"))
  add(num_arg(p$protein_quant_qvalue, "--protein-quant-qvalue"))
  add(num_arg(p$matrix_qvalue, "--matrix-qvalue"))

  # --- 修饰 ---
  add(num_arg(p$var_mods_max, "--var-mods"))
  for (m in p$var_mod_rows) {
    if (all(nz_str(m))) ch <- c(ch, paste0("--var-mod ", shQuote(sprintf("%s,%s,%s", m[1], m[2], m[3]))))
  }
  for (m in p$fixed_mod_rows) {
    if (all(nz_str(m))) ch <- c(ch, paste0("--fixed-mod ", shQuote(sprintf("%s,%s,%s", m[1], m[2], m[3]))))
  }
  add(flag_arg(p$met_excision, "--met-excision"))
  add(flag_arg(p$reannotate, "--reannotate"))

  # --- FASTA 搜索 / 库构建 ---
  add(flag_arg(p$fasta_search, "--fasta-search"))
  add(flag_arg(isTRUE(p$use_cut) && nz_str(p$cut), paste0("--cut ", shQuote(p$cut))))
  add(num_arg(p$missed_cleavages, "--missed-cleavages"))
  add(num_arg(p$min_pep_len, "--min-pep-len"))
  add(num_arg(p$max_pep_len, "--max-pep-len"))
  add(num_arg(p$min_pr_mz, "--min-pr-mz"))
  add(num_arg(p$max_pr_mz, "--max-pr-mz"))
  add(num_arg(p$min_pr_charge, "--min-pr-charge"))
  add(num_arg(p$max_pr_charge, "--max-pr-charge"))
  add(num_arg(p$min_fr_mz, "--min-fr-mz"))
  add(num_arg(p$max_fr_mz, "--max-fr-mz"))
  add(flag_arg(p$predictor, "--predictor"))
  add(flag_arg(p$light_models, "--light-models"))
  add(flag_arg(p$gen_spec_lib, "--gen-spec-lib"))
  # --out-lib 只在勾选「生成谱图库」时才有意义: 未勾选却写入会被 DIA-NN 忽略/报错,
  # 且会造成「填了路径却没建库」的假象。
  if (isTRUE(p$gen_spec_lib)) {
    out_lib_val <- p$out_lib
    if (!nz_str(out_lib_val) && nz_str(p$out_dir)) out_lib_val <- file.path(p$out_dir, "library.speclib")
    add(str_arg(out_lib_val, "--out-lib"))
  }
  add(num_arg(p$out_lib_qvalue, "--out-lib-qvalue"))

  # --- 高级 ---
  add(flag_arg(p$export_quant, "--export-quant"))
  add(flag_arg(p$report_decoys, "--report-decoys"))
  add(flag_arg(p$individual_windows, "--individual-windows"))
  add(flag_arg(p$individual_mass_acc, "--individual-mass-acc"))
  add(flag_arg(p$global_norm, "--global-norm"))
  add(flag_arg(p$no_rt_norm, "--no-rt-norm"))
  add(flag_arg(p$no_prot_norm, "--no-prot-norm"))
  add(flag_arg(p$high_acc, "--high-acc"))
  add(flag_arg(p$no_skyline, "--no-skyline"))
  add(flag_arg(p$no_stats, "--no-stats"))
  add(pos_arg(p$xic, "--xic"))
  add(num_arg(p$min_corr, "--min-corr"))

  # --- 额外参数（自由文本，压缩为单行后原样追加） ---
  if (nz_str(p$extra)) ch <- c(ch, trimws(gsub("\\s*\\n\\s*", " ", p$extra)))

  ch
}
# ---- 共享作业体与脚本头 (v1.12: Slurm 可选 / 本地执行) ----------------------
# job_body() 是两种后端共用的程序体: apptainer 运行时定位回退链 → 容器内
# diann-linux → .rc 退出码 → DIANN_GUI_START/END_EPOCH → exit $rc。
# 四层状态判定的层 2/3 依赖 .rc 与 epoch 标记, 因此两种后端必须共用同一程序体
# (仅末尾注释里的"调度态"措辞不同)。Slurm 脚本输出保持 v1.11 原样。
job_body <- function(p, backend = "slurm") {
  args <- paste(build_diann_chunks(p), collapse = " \\\n    ")
  sc1 <- function(x) if (is.null(x) || length(x) == 0) "" else as.character(x)
  # ---- apptainer 运行环境: GUI 选定路径优先, 不可见时按候选目录 → PATH → module 回退 ----
  # 选定路径放在脚本里 (同一个共享存储路径在计算节点通常也可见); 回退链保证
  # "只在计算节点安装"或"只配了 module"的集群仍能跑。找不到时不提前退出, 让
  # "$APPTAINER_BIN" exec 自然返回 127, 仍走下方 rc/.rc 单一通道进入四层状态判定。
  ap_sel <- if (nz_str(p$apptainer_bin)) trimws(p$apptainer_bin) else "apptainer"
  ap_dirs <- cfg_get("APPTAINER_PATHS") %||% character(0)
  ap_dirs <- ap_dirs[!is.na(ap_dirs) & nzchar(ap_dirs)]
  ap_dir_loop <- if (length(ap_dirs)) {
    paste0(
      'if [ ! -x "$APPTAINER_BIN" ]; then\n',
      '  for d in ', paste(shQuote(ap_dirs), collapse = " "), '; do\n',
      '    for n in apptainer singularity; do\n',
      '      if [ -x "$d/$n" ]; then APPTAINER_BIN="$d/$n"; break 2; fi\n',
      '    done\n',
      '  done\n',
      'fi\n')
  } else ""
  ap_module <- if (nzchar(cfg_get("APPTAINER_MODULE_FALLBACK") %||% "")) {
    # 先 source /etc/profile.d/modules.sh: 它导出站点真实 MODULEPATH (login shell 才加载,
    # sbatch 的非 login bash 里缺它, 仅 init/bash 的默认 MODULEPATH 找不到站点模块)
    sprintf(paste0('if [ ! -x "$APPTAINER_BIN" ]; then\n',
                   '  source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null\n',
                   '  module load %s 2>/dev/null\n',
                   'fi\n'),
            cfg_get("APPTAINER_MODULE_FALLBACK"))
  } else ""
  apptainer_init_str <- paste0(
    "APPTAINER_BIN=", shQuote(ap_sel), "\n",
    ap_dir_loop,
    'if [ ! -x "$APPTAINER_BIN" ]; then\n',
    '  APPTAINER_BIN=$(command -v apptainer 2>/dev/null || true)\n',
    'fi\n',
    ap_module,
    'if [ ! -x "$APPTAINER_BIN" ]; then\n',
    '  APPTAINER_BIN=$(command -v apptainer 2>/dev/null || command -v singularity 2>/dev/null || true)\n',
    'fi\n',
    # conda 安装的 apptainer 依赖同目录的 squashfuse 等辅助程序, 必须前置 PATH
    'export PATH="$(dirname "${APPTAINER_BIN:-apptainer}"):$PATH"\n',
    'echo "DIANN_GUI_APPTAINER ${APPTAINER_BIN:-NOT-FOUND}"\n',
    '[ -x "$APPTAINER_BIN" ] || echo "ERROR: apptainer/singularity not found (GUI selected: ',
    gsub('"', "'", ap_sel), ')" >&2'
  )
  bind_args <- if (length(cfg_get("BIND_PATHS"))) paste0("--bind ", shQuote(cfg_get("BIND_PATHS")), collapse = " ") else ""
  # 程序层退出码落盘 (四层状态判定的第二层来源): apptainer exec 的返回码;
  # 容器卸载阶段偶发 SIGILL 会把 rc 污染为 132, 由 GUI 状态合成判为"待核实"而非失败
  rc_file <- sub("\\.sh$", ".rc", sc1(p$script_path %||% "diann_gui_preview.sh"))
  state_word <- if (identical(backend, "local")) "本地进程态" else "Slurm 终态"
  sprintf("%s\n\necho \"DIA-NN analysis start: $(date)\"\necho \"DIANN_GUI_START_EPOCH $(date +%%s)\"\n\n\"$APPTAINER_BIN\" exec %s %s diann-linux %s\nrc=$?\nprintf '%%s' \"$rc\" > %s\necho \"DIA-NN analysis done: $(date), exit code: $rc\"\necho \"DIANN_GUI_END_EPOCH $(date +%%s)\"\n\n# 如实退出, 成败由 GUI 的四层状态合成判定 (%s + 程序退出码 + 产物验证)\nexit $rc\n",
    apptainer_init_str, bind_args, shQuote(sc1(p$sif)), args, shQuote(rc_file), state_word)
}

# Slurm 服务器脚本头 (-J/-p/资源/时限/-o/-e/站点额外 #SBATCH)
slurm_script_header <- function(p) {
  sc1 <- function(x) if (is.null(x) || length(x) == 0) "" else as.character(x)
  # 时限按分钟提交: 1.9 h -> -t 114, 0.5 h -> -t 30。旧实现 as.integer(h) 会把 1.9 截成 1 h,
  # 且 server 曾把 <1 h 转成 NA 变成"不限时"——用户明确限时却得到无限, 属资源安全问题。
  time_line <- if (!is.null(p$time_h) && length(p$time_h) == 1 && !is.na(p$time_h)) {
    sprintf("#SBATCH -t %d\n", max(1L, as.integer(ceiling(60 * p$time_h))))
  } else ""
  # 站点额外 #SBATCH 选项 (--account/--qos/--reservation 等), 逐行写入
  slurm_extra <- cfg_get("SLURM_EXTRA_ARGS") %||% character(0)
  slurm_extra <- trimws(slurm_extra[!is.na(slurm_extra) & nzchar(slurm_extra)])
  slurm_extra_lines <- if (length(slurm_extra)) paste0(paste0("#SBATCH ", slurm_extra), collapse = "\n") else ""
  # 空字符串时保留一个空行, 避免把下面的 #SBATCH -o 粘到 -e 后
  if (!nzchar(slurm_extra_lines)) slurm_extra_lines <- ""
  sprintf("#!/bin/bash\n#SBATCH -J %s\n#SBATCH -p %s\n#SBATCH --nodes=1\n#SBATCH --cpus-per-task=%s\n#SBATCH --mem=%sG\n%s#SBATCH -o %s\n#SBATCH -e %s\n%s\n\n",
          shQuote(sc1(p$job_name)), sc1(p$partition), sc1(as.integer(p$threads)), sc1(as.integer(p$mem_gb)),
          time_line, shQuote(sc1(p$slurm_out)), shQuote(sc1(p$slurm_err)), slurm_extra_lines)
}

make_slurm_script <- function(p) paste0(slurm_script_header(p), job_body(p, "slurm"))

# 本地模式脚本: 共用同一个 job_body, 只去掉 #SBATCH 头。stdout/stderr 重定向、
# 时限 timeout、退出码补写与 .cancelled/.timeout 标记由 inst/scripts/local_runner.sh 接管。
make_local_script <- function(p) {
  sc1 <- function(x) if (is.null(x) || length(x) == 0) "" else as.character(x)
  mins <- if (!is.null(p$time_h) && length(p$time_h) == 1 && !is.na(p$time_h)) {
    max(1L, as.integer(ceiling(60 * p$time_h)))
  } else 0L
  rc_file <- sub("\\.sh$", ".rc", sc1(p$script_path %||% "diann_gui_preview.sh"))
  paste0(
    "#!/bin/bash\n",
    "# diann.gui 本地执行脚本 (无 Slurm) — 由 inst/scripts/local_runner.sh 启动\n",
    sprintf("# 程序退出码写入: %s; 日志由运行器重定向为 local-<ID>.out/.err\n", rc_file),
    sprintf("# 时限: %s\n\n", if (mins > 0L) sprintf("%d 分钟 (由运行器 timeout 强制执行)", mins) else "不限"),
    job_body(p, "local"))
}

# 预览与提交统一入口: 按执行后端生成脚本
make_job_script <- function(p, backend = "slurm") {
  if (identical(backend, "local")) make_local_script(p) else make_slurm_script(p)
}
# 命令导入解析（纯函数）：识别 DIA-NN 命令并映射到 GUI 控件
# ============================================================

# 布尔旗标 -> 输入控件 id
BOOL_FLAG_MAP <- c(
  "--reanalyse" = "mbr", "--rt-profiling" = "rt_prof", "--peptidoforms" = "peptidoforms",
  "--proteoforms" = "proteoforms", "--matrices" = "matrices", "--individual-reports" = "indiv_reports",
  "--unimod4" = "unimod4", "--met-excision" = "met_excision", "--reannotate" = "reannotate",
  "--predictor" = "predictor", "--light-models" = "light_models", "--gen-spec-lib" = "gen_spec_lib",
  "--export-quant" = "export_quant", "--report-decoys" = "report_decoys",
  "--individual-windows" = "individual_windows", "--individual-mass-acc" = "individual_mass_acc",
  "--global-norm" = "global_norm", "--no-rt-norm" = "no_rt_norm", "--no-prot-norm" = "no_prot_norm",
  "--high-acc" = "high_acc", "--no-skyline" = "no_skyline", "--no-stats" = "no_stats",
  "--fasta-search" = "fasta_search", "--convert" = "convert_only"
)
# 数值旗标 -> 输入控件 id (--verbose 在导入时特殊处理为 selectInput)
NUM_FLAG_MAP <- c(
  "--qvalue" = "qvalue", "--threads" = "threads", "--verbose" = "verbose", "--mass-acc" = "mass_acc",
  "--mass-acc-ms1" = "mass_acc_ms1", "--window" = "window", "--min-peak" = "min_peak",
  "--rt-window" = "rt_window", "--im-window" = "im_window", "--quant-qvalue" = "quant_qvalue",
  "--protein-quant-qvalue" = "protein_quant_qvalue", "--matrix-qvalue" = "matrix_qvalue",
  "--var-mods" = "var_mods_max", "--missed-cleavages" = "missed_cleavages",
  "--min-pep-len" = "min_pep_len", "--max-pep-len" = "max_pep_len",
  "--min-pr-mz" = "min_pr_mz", "--max-pr-mz" = "max_pr_mz",
  "--min-pr-charge" = "min_pr_charge", "--max-pr-charge" = "max_pr_charge",
  "--min-fr-mz" = "min_fr_mz", "--max-fr-mz" = "max_fr_mz",
  "--out-lib-qvalue" = "out_lib_qvalue", "--xic" = "xic", "--min-corr" = "min_corr"
)
# 文本旗标 -> 输入控件 id
TEXT_FLAG_MAP <- c("--cut" = "cut", "--out-lib" = "out_lib", "--cont-quant-exclude" = "cont_tag")
# 需要取值的路径类旗标; Windows GUI 在路径留空时导出裸旗标 (无取值, 如 "--lib --f ...")
PATH_VALUE_FLAGS <- c("--f", "--fasta", "--lib", "--ref", "--temp", "--out", "--out-dir", "--out-lib", "--dir", "--dir-all")

is_win_path <- function(x) grepl("^[A-Za-z]:\\\\", x) || grepl("\\\\", x)

# 引号感知分词
tokenize_cmd <- function(s) {
  toks <- character(0); cur <- ""; has <- FALSE; q <- ""
  for (ch in strsplit(s, "", fixed = TRUE)[[1]]) {
    if (nzchar(q)) {
      if (ch == q) q <- "" else cur <- paste0(cur, ch)
    } else if (ch == "'" || ch == '"') {
      q <- ch; has <- TRUE
    } else if (ch == " " || ch == "\t") {
      if (has || nzchar(cur)) { toks <- c(toks, cur); cur <- ""; has <- FALSE }
    } else { cur <- paste0(cur, ch); has <- TRUE }
  }
  if (has || nzchar(cur)) toks <- c(toks, cur)
  toks
}

parse_diann_command <- function(text) {
  res <- list(
    bool = character(0), num = list(), text = list(),
    var_mods = list(), fixed_mods = list(),
    files = list(raws = character(0), raw_dir = "", fastas = character(0), lib = "", ref = "", temp = "", out_dir = ""),
    report_name = "", windows_paths = character(0), unknown = character(0), cont_fasta = FALSE,
    bare = character(0), bare_lib = FALSE
  )
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  # 本页预览的 Slurm 脚本: "rc=$?" 行是 diann 命令的固定收尾, 其后 (含该行) 是脚本杂项,
  # 不再扫描——否则尾部裸旗标会把 "rc=$?" 吞成取值 (曾致主报告文件名变成 "rc=$?")
  rc_cut <- grep("^\\s*rc=\\$\\?\\s*$", lines)
  if (length(rc_cut)) lines <- lines[seq_len(rc_cut[1]) - 1L]
  # Slurm 头部 #SBATCH -o/-e 蕴含输出目录: 预测库脚本无 --out, 导入时由此回填
  sbatch_cand <- c(grep("^\\s*#SBATCH.*\\s-o\\s+", lines, value = TRUE),
                   grep("^\\s*#SBATCH.*\\s--output=", lines, value = TRUE),
                   grep("^\\s*#SBATCH.*\\s-e\\s+", lines, value = TRUE))
  slurm_out_dir <- ""
  if (length(sbatch_cand)) {
    otok <- tokenize_cmd(sbatch_cand[1])
    if (length(otok)) {
      cand <- sub("^--output=", "", otok[length(otok)])
      if (startsWith(cand, "/")) slurm_out_dir <- dirname(cand)
    }
  }
  lines <- lines[!grepl("^\\s*#", lines)]
  s <- paste(lines, collapse = " ")
  s <- gsub("\\ ", " ", s, fixed = TRUE)  # 合并反斜杠续行 (不影响 Windows 路径中的反斜杠)
  toks <- tokenize_cmd(s)
  start <- 0
  for (i in seq_along(toks)) {
    if (basename(toks[i]) %in% c("diann-linux", "diann.exe", "diann")) { start <- i + 1; break }
  }
  args <- if (start > 0) toks[start:length(toks)] else toks

  i <- 1; n <- length(args)
  while (i <= n) {
    t <- args[i]
    if (!grepl("^--", t)) { i <- i + 1; next }
    nxt <- if (i < n) args[i + 1] else NA_character_
    if (t %in% names(BOOL_FLAG_MAP)) { res$bool <- c(res$bool, t); i <- i + 1; next }
    if (is.na(nxt) || grepl("^--", nxt)) {
      # 路径类旗标无取值 (Windows GUI 路径留空时导出裸旗标): 只记录不塞进额外参数,
      # 否则残留的裸旗标会让 diann-linux 直接报错并被校验拦截
      if (t %in% PATH_VALUE_FLAGS) {
        res$bare <- c(res$bare, t)
        if (t == "--lib") res$bare_lib <- TRUE
      } else {
        res$unknown <- c(res$unknown, t)
      }
      i <- i + 1; next
    }
    win <- is_win_path(nxt)
    if (win) res$windows_paths <- c(res$windows_paths, paste(t, nxt))
    if (t == "--f") {
      if (!win) res$files$raws <- c(res$files$raws, nxt)
    } else if (t == "--fasta") {
      if (!win) res$files$fastas <- c(res$files$fastas, nxt)
    } else if (t == "--lib") {
      if (!win) res$files$lib <- nxt
    } else if (t == "--ref") {
      if (!win) res$files$ref <- nxt
    } else if (t == "--temp") {
      if (!win) res$files$temp <- nxt
    } else if (t %in% c("--dir", "--dir-all")) {
      # 目录模式 (DIA-NN Windows GUI 选择文件夹时导出 --dir / --dir-all)
      if (!win) res$files$raw_dir <- nxt
    } else if (t == "--out-dir") {
      if (!win) res$files$out_dir <- nxt
    } else if (t == "--out") {
      if (!win) {
        res$files$out_dir <- dirname(nxt)
        # DIA-NN 2.x 主报告默认 .parquet; 两种后缀都要剥离, 否则 GUI 会生成 x.parquet.tsv
        res$report_name <- sub("(?i)\\.(tsv|parquet)$", "", basename(nxt), perl = TRUE)
      }
    } else if (t == "--var-mod") {
      parts <- strsplit(nxt, ",", fixed = TRUE)[[1]]
      res$var_mods <- c(res$var_mods, list(c(parts, rep("", 3))[1:3]))
    } else if (t == "--fixed-mod") {
      parts <- strsplit(nxt, ",", fixed = TRUE)[[1]]
      res$fixed_mods <- c(res$fixed_mods, list(c(parts, rep("", 3))[1:3]))
    } else if (t %in% names(NUM_FLAG_MAP)) {
      v <- suppressWarnings(as.numeric(nxt))
      if (!is.na(v)) res$num[[t]] <- v else res$unknown <- c(res$unknown, t)
    } else if (t %in% names(TEXT_FLAG_MAP)) {
      res$text[[t]] <- nxt
    } else {
      res$unknown <- c(res$unknown, paste(t, nxt))
    }
    i <- i + 2
  }
  # 裸 --lib + 无 RAW 文件 = Windows GUI 预测库生成命令 (谱库路径留空待填): 转为 --gen-spec-lib 意图,
  # 导入后自动勾选「生成谱图库」; 有 RAW 时 --lib 仅是留空的谱库输入位, 不推断
  if (isTRUE(res$bare_lib) && length(res$files$raws) == 0) {
    res$bool <- c(res$bool, "--gen-spec-lib")
  }
  # 命令本身无 --out/--out-dir (如预测库脚本) 时, 用 SBATCH -o 的目录回填输出目录
  if (!nzchar(res$files$out_dir) && nzchar(slurm_out_dir)) res$files$out_dir <- slurm_out_dir
  # 粘贴命令中若含内置污染物库, 转为污染物开关而非普通 FASTA
  if (length(res$files$fastas)) {
    hit <- res$files$fastas == cfg_get("CON_FASTA")
    if (any(hit)) {
      res$files$fastas <- res$files$fastas[!hit]
      res$cont_fasta <- TRUE
    }
  }
  res
}
# 导入后 var_mods_max 的取值: 命令显式给出 --var-mods 时以显式值优先 (数值旗标循环已写入),
# 修饰行数仅在无旗标时兜底 (reset 后 UI 基线为默认 1), 两者皆无返回 NULL 保持基线。
# 行数不得覆盖显式值 —— 2026-10-12 事故: --var-mods 5 + 2 行修饰被写成 2, 集群重建库前体数少 12 万
imported_var_mods_max <- function(pr) {
  v <- pr$num[["--var-mods"]]
  if (!is.null(v)) return(v)
  if (length(pr$var_mods)) return(min(length(pr$var_mods), 6L))
  NULL
}
# 修饰行（变量修饰 6 行，默认前两行 = 氧化 M + 蛋白 N 端乙酰；固定修饰 3 行）
vm_default <- function(i, col) {
  rows <- list(
    c("UniMod:35", "15.994915", "M"),
    c("UniMod:1", "42.010565", "*n")
  )
  if (i <= length(rows)) rows[[i]][col] else ""
}
