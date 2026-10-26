# 真实用户粘贴回归夹具 (2026-10-09 导入断连事故):
# 两份命令均含真实服务器路径, 曾因 app.R source 环境作用域 bug 导致会话断连。
# 本文件固化其解析/范围/构建契约; 浏览器端到端验证另见 tests/e2e/run_e2e.sh。
FIX_DIR <- FIXTURES_DIR
read_fixture <- function(name) paste(readLines(file.path(FIX_DIR, name), warn = FALSE), collapse = "\n")

test_that("夹具: 小命令 (39 RAW, 经验谱库+建库工作流) 完整解析", {
  r <- parse_diann_command(read_fixture("import_small_userpaste.txt"))
  expect_length(r$files$raws, 39)
  expect_length(r$files$fastas, 2)
  expect_true(nzchar(r$files$lib))
  expect_equal(r$files$out_dir, "/share/home/demo/project/labuser/project_alpha/result/build_library_demo")
  expect_equal(r$report_name, "report_fasta")
  expect_setequal(r$bool, c("--reanalyse", "--rt-profiling", "--peptidoforms", "--matrices",
                            "--unimod4", "--met-excision", "--gen-spec-lib"))
  expect_length(r$unknown, 0)
  expect_length(r$windows_paths, 0)
  expect_true(isTRUE(r$cont_fasta) || nzchar(r$text[["--cont-quant-exclude"]]))
  expect_equal(r$num[["--threads"]], 20)
})

test_that("夹具: 大命令 (796 RAW, 98KB) 完整解析", {
  r <- parse_diann_command(read_fixture("import_large_userpaste.txt"))
  expect_length(r$files$raws, 796)
  expect_length(r$files$fastas, 2)
  expect_true(nzchar(r$files$lib))
  expect_equal(r$report_name, "report_fasta")
  expect_length(r$unknown, 0)
  expect_length(r$windows_paths, 0)
  expect_equal(r$num[["--threads"]], 40)
})

test_that("夹具全部路径落在数据范围内 (path_in_scope)", {
  set_core_const("BASE_VOLUMES", c(Data = "/share"))
  on.exit(set_core_const("BASE_VOLUMES", c(Data = tempdir())), add = TRUE)
  for (fx in c("import_small_userpaste.txt", "import_large_userpaste.txt")) {
    r <- parse_diann_command(read_fixture(fx))
    expect_true(all(path_in_scope(r$files$raws)),
                info = sprintf("%s: 存在范围外路径", fx))
    expect_true(path_in_scope(r$files$lib), info = fx)
  }
})

test_that("夹具端到端构建: 解析->参数映射->sbatch 脚本含全部 RAW 与 rcfile", {
  e <- new.env(parent = globalenv())
  set_core_const("CON_FASTA", "/share/home/demo/data/fasta/cRAP_contaminants.fasta")
  set_core_const("BASE_VOLUMES", c(Data = "/share"))
  set_core_const("APPTAINER_PATHS", "/opt/apptainer/bin")
  set_core_const("APPTAINER_MODULE_FALLBACK", "")
  set_core_const("BIND_PATHS", "/share")
  on.exit({
    set_core_const("CON_FASTA", "")
    set_core_const("BASE_VOLUMES", c(Data = tempdir()))
    set_core_const("APPTAINER_PATHS", character(0))
    set_core_const("APPTAINER_MODULE_FALLBACK", "")
    set_core_const("BIND_PATHS", character(0))
  }, add = TRUE)

  mk_params <- function(fx, script_path) {
    r <- parse_diann_command(read_fixture(fx))
    b <- setNames(as.list(rep(TRUE, length(r$bool))), unname(BOOL_FLAG_MAP[r$bool]))
    nums <- as.list(r$num)
    names(nums) <- unname(NUM_FLAG_MAP[names(r$num)])
    p <- list(
      job_name = "T", partition = "compute", threads = r$num[["--threads"]], mem_gb = 64,
      time_h = NA_real_, sif = "/x/diann.sif", ver = "x",
      slurm_out = "/o/slurm-%j.out", slurm_err = "/o/slurm-%j.err", script_path = script_path,
      raw_mode = "files", raws = r$files$raws, raw_dir = "", lib = r$files$lib,
      ref = "", fastas = r$files$fastas, temp = "", out_dir = r$files$out_dir,
      out_file = file.path(r$files$out_dir, paste0(r$report_name, ".tsv")),
      verbose = as.integer(r$num[["--verbose"]]), qvalue = r$num[["--qvalue"]],
      var_mods_max = r$num[["--var-mods"]],
      var_mod_rows = r$var_mods, fixed_mod_rows = r$fixed_mods,
      use_cut = TRUE, cut = r$text[["--cut"]] %||% "K*,R*",
      cont_exclude = TRUE, cont_tag = r$text[["--cont-quant-exclude"]],
      gen_spec_lib = "--gen-spec-lib" %in% r$bool,
      fasta_search = FALSE, out_lib = "", out_lib_qvalue = NA, extra = "", convert_only = FALSE
    )
    # 未被夹具设置的分析参数补默认 (与 GUI 留空一致)
    defaults <- c("mass_acc","mass_acc_ms1","window","min_peak","rt_window","im_window",
                  "quant_qvalue","protein_quant_qvalue","matrix_qvalue","missed_cleavages",
                  "min_pep_len","max_pep_len","min_pr_mz","max_pr_mz","min_pr_charge",
                  "max_pr_charge","min_fr_mz","max_fr_mz","xic","min_corr","predictor",
                  "light_models","export_quant","report_decoys","individual_windows",
                  "individual_mass_acc","global_norm","no_rt_norm","no_prot_norm","high_acc",
                  "no_skyline","no_stats","reanalyse","rt_prof","peptidoforms","proteoforms",
                  "matrices","indiv_reports","unimod4","met_excision","reannotate")
    for (nm in defaults) if (is.null(p[[nm]])) p[[nm]] <- NA
    for (nm in names(nums)) p[[nm]] <- nums[[nm]]
    for (fl in r$bool) p[[unname(BOOL_FLAG_MAP[[fl]])]] <- TRUE
    p
  }
  for (fx in c("import_small_userpaste.txt", "import_large_userpaste.txt")) {
    p <- mk_params(fx, "/o/diann_gui_scripts/diann_fixture.sh")
    s <- make_slurm_script(p)
    n_raw_in_script <- sum(gregexpr("--f '/share/home/demo/project/labuser", s, fixed = TRUE)[[1]] != -1L)
    expected <- length(parse_diann_command(read_fixture(fx))$files$raws)
    expect_identical(n_raw_in_script, expected,
                     info = sprintf("%s: 脚本中 RAW 数量", fx))
    expect_match(s, "printf '%s' \"$rc\"", fixed = TRUE)
    expect_match(s, "exit $rc", fixed = TRUE)
    expect_false(grepl("final_rc", s))
  }
})

# 2026-10-12 事故: Windows GUI 预测库命令以裸 --lib 开头、裸 --out 收尾 (路径留空),
# 导入后被塞进「额外参数」且生成谱图库未勾选, 校验同时报 RAW 缺失与裸旗标缺取值
test_that("夹具: Windows 预测库粘贴 (裸 --lib/--out) 推断生成谱图库且不污染额外参数", {
  r <- parse_diann_command(read_fixture("import_windows_predlib_userpaste.txt"))
  expect_true(r$bare_lib)
  expect_setequal(r$bare, c("--lib", "--out"))
  expect_true("--gen-spec-lib" %in% r$bool)   # 无 RAW + 裸 --lib => 生成预测库意图
  expect_length(r$unknown, 0)                 # 裸旗标不再残留到「额外参数」
  expect_length(r$files$raws, 0)
  expect_length(r$files$fastas, 0)            # M:\ FASTA 为 Windows 路径, 跳过待用户重选
  expect_length(r$windows_paths, 1)
  expect_equal(r$num[["--threads"]], 32)
  expect_equal(r$num[["--var-mods"]], 5)
  expect_length(r$var_mods, 2)
  expect_equal(r$text[["--cut"]], "K*,R*")
})

# 2026-10-12 事故: 导入命令的显式 --var-mods 5 曾被 2 行修饰覆盖成 2,
# 集群按 --var-mods 2 重建库, 前体数少 12 万 (8,886,681 -> 8,764,376)
test_that("导入 var_mods_max: 显式 --var-mods 优先, 修饰行数仅兜底", {
  r <- parse_diann_command(read_fixture("import_windows_predlib_userpaste.txt"))
  expect_equal(imported_var_mods_max(r), 5)   # 显式 5 ≠ 修饰行数 2, 不得写成 2
  # 无显式旗标、仅有修饰行: 按行数兜底 (reset 后 UI 基线为默认 1)
  r2 <- parse_diann_command(paste("diann --gen-spec-lib --out /share/x/lib.parquet",
                                  "--var-mod UniMod:35,15.994915,M",
                                  "--var-mod UniMod:1,42.010565,*n"))
  expect_equal(imported_var_mods_max(r2), 2)
  expect_null(imported_var_mods_max(parse_diann_command("diann --out /share/x/report.tsv")))
})

# 2026-10-12 第二例: 粘贴本页预览的 Slurm 脚本 (小鼠预测库), rc=$? 等脚本尾部行曾被扫进参数
test_that("夹具: 预览 Slurm 脚本 (预测库) 导入——rc=$? 截断 + SBATCH 输出目录回填", {
  r <- parse_diann_command(read_fixture("import_slurm_predlib_preview.txt"))
  expect_equal(r$report_name, "")   # rc=$? 不再被吞成主报告文件名
  expect_length(r$unknown, 0)
  expect_length(r$bare, 0)
  expect_equal(r$files$out_dir, "/share/home/demo/data/library/mouse")  # 来自 #SBATCH -o
  expect_equal(r$files$fastas,
               "/share/home/demo/data/fasta/mouse_proteome_reviewed.fasta")
  expect_equal(r$text[["--out-lib"]], "/share/home/demo/data/library/mouse/library.speclib")
  expect_true("--gen-spec-lib" %in% r$bool)   # 脚本显式携带
  expect_equal(r$num[["--threads"]], 32)
  expect_length(r$var_mods, 2)
})

# 2026-10 审查: --dir/--dir-all (Windows GUI 选择文件夹时导出) 此前被当成未知旗标,
# RAW 目录不进入覆盖层, 导入后校验报"未选择 RAW 文件/目录"而无法提交。
test_that("夹具: 目录模式命令 (--dir-all) 解析为 RAW 目录", {
  r <- parse_diann_command(read_fixture("import_dir_userpaste.txt"))
  expect_equal(r$files$raw_dir, "/share/home/demo/data/raw/demo_batch_07")
  expect_length(r$files$raws, 0)
  expect_length(r$unknown, 0)
  expect_equal(r$report_name, "report")
  expect_equal(r$num[["--threads"]], 24)
  expect_true(all(c("--matrices", "--reanalyse", "--rt-profiling") %in% r$bool))
})

test_that("目录模式夹具端到端: 构建脚本含 --dir-all", {
  r <- parse_diann_command(read_fixture("import_dir_userpaste.txt"))
  p <- base_params(list(raw_mode = "dir", raw_dir = r$files$raw_dir, raws = character(0),
                        lib = r$files$lib, out_dir = r$files$out_dir,
                        out_file = file.path(r$files$out_dir, "report.tsv")))
  ch <- build_diann_chunks(p)
  expect_true(any(grepl(sprintf("--dir-all '%s'", r$files$raw_dir), ch, fixed = TRUE)))
  expect_false(any(grepl("^--f ", ch)))
})

test_that("目录夹具路径落在数据范围内", {
  set_core_const("BASE_VOLUMES", c(Data = "/share"))
  on.exit(set_core_const("BASE_VOLUMES", c(Data = tempdir())), add = TRUE)
  r <- parse_diann_command(read_fixture("import_dir_userpaste.txt"))
  expect_true(path_in_scope(r$files$raw_dir))
  expect_true(path_in_scope(r$files$lib))
  expect_true(path_in_scope(r$files$out_dir))
})
