# ============================================================
# apptainer.R — apptainer 可执行探测与调用 (GUI 节点侧)
# ============================================================
# 探测结果供「运行环境自检」面板展示与「验证镜像可用性」按钮使用;
# 计算节点侧仍由 sbatch 脚本自行回退 (PATH 候选 → module load),
# GUI 探测失败不阻断提交。结果由 run_app() 启动时写入配置环境
# (.cfg$APPTAINER_PROBE), server 经 cfg_get 读取。

apptainer_run <- function(bin, args, timeout = 30) {
  # 经 bash 显式前置 apptainer 所在目录到 PATH: conda 安装的 apptainer 依赖同目录的
  # squashfuse 等辅助程序, 不前置 PATH 时 exec 会以 "squashfuse not found" 失败 (实测)
  payload <- sprintf('PATH=%s:"$PATH" exec %s %s', shQuote(dirname(bin)), shQuote(bin), paste(args, collapse = " "))
  system2("bash", c("-c", shQuote(payload)), stdout = TRUE, stderr = TRUE, timeout = timeout)
}

apptainer_probe <- function() {
  cand <- character(0); src <- character(0)
  w <- unname(Sys.which("apptainer"))
  if (nz_str(w)) { cand <- c(cand, w); src <- c(src, "PATH") }
  for (d in cfg_get("APPTAINER_PATHS")[nzchar(cfg_get("APPTAINER_PATHS"))]) {
    f <- file.path(d, "apptainer")
    np <- normalizePath(cand, mustWork = FALSE)
    if (file.exists(f) && file.access(f, 1) == 0 && !normalizePath(f, mustWork = FALSE) %in% np) {
      cand <- c(cand, f); src <- c(src, "APPTAINER_PATHS")
    }
  }
  vers <- vapply(seq_along(cand), function(i) {
    out <- tryCatch(suppressWarnings(apptainer_run(cand[i], "--version", timeout = 10)), error = function(e) NULL)
    if (is.character(out) && any(nzchar(out))) trimws(tail(out[nzchar(out)], 1)) else ""
  }, character(1))
  module_line <- NULL
  if (nzchar(cfg_get("APPTAINER_MODULE_FALLBACK") %||% "")) {
    module_line <- tryCatch({
      # /etc/profile.d/modules.sh (login shell 才加载) 导出站点真实 MODULEPATH;
      # 非 login 的 bash -c / shiny worker 环境缺它时 module load 必失败, 故先 source 它
      pl <- sprintf(paste0('source /etc/profile.d/modules.sh 2>/dev/null || source /usr/share/Modules/init/bash 2>/dev/null; ',
                           'module load %s 2>/dev/null && command -v apptainer'),
                    cfg_get("APPTAINER_MODULE_FALLBACK"))
      out <- suppressWarnings(system2("bash", c("-c", shQuote(pl)), stdout = TRUE, stderr = TRUE, timeout = 15))
      list(ok = is.character(out) && any(nzchar(out)),
           path = if (is.character(out)) tail(out[nzchar(out)], 1) else "")
    }, error = function(e) list(ok = FALSE, path = ""))
  }
  list(ok = length(cand) > 0, bins = cand, src = src, vers = vers, module = module_line)
}
