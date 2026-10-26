# build_diann_chunks / make_slurm_script: 命令构建与 sbatch 模板
test_that("files 模式逐个 --f, dir 模式用 --dir-all", {
  p <- base_params()
  ch <- build_diann_chunks(p)
  expect_true(any(ch == "--f '/d/a.raw'"))
  p2 <- base_params(list(raw_mode = "dir", raw_dir = "/d/rawdir", raws = c()))
  ch2 <- build_diann_chunks(p2)
  expect_true(any(grepl("--dir-all '/d/rawdir'", ch2, fixed = TRUE)))
  expect_false(any(grepl("^--f ", ch2)))
})

test_that("输入判定以实际内容为准: dir 模式只有 raws 仍生成 --f, 只有目录则回退 --dir-all", {
  # 导入的 RAW 覆盖层与 raw_mode 可能不一致: 旧实现只看 raw_mode 会静默丢掉 raws
  p <- base_params(list(raw_mode = "dir", raw_dir = "", raws = c("/d/a.raw", "/d/b.raw")))
  ch <- build_diann_chunks(p)
  expect_true(any(grepl("--f '/d/a.raw'", ch, fixed = TRUE)))
  expect_true(any(grepl("'/d/b.raw'", ch, fixed = TRUE)))
  expect_false(any(grepl("--dir-all", ch, fixed = TRUE)))
  p2 <- base_params(list(raw_mode = "files", raw_dir = "/d/rawdir", raws = character(0)))
  ch2 <- build_diann_chunks(p2)
  expect_true(any(grepl("--dir-all '/d/rawdir'", ch2, fixed = TRUE)))
  expect_false(any(grepl("^--f ", ch2)))
})

test_that("转换模式输出最小命令并忽略分析参数", {
  p <- base_params(list(convert_only = TRUE, matrices = TRUE, qvalue = 0.001))
  ch <- build_diann_chunks(p)
  expect_true("--convert" %in% ch)
  expect_false(any(grepl("--matrices", ch)))
  expect_false(any(grepl("--qvalue", ch)))
  expect_true(any(ch == "--threads 16"))
})

test_that("修饰行与额外参数正确拼入", {
  p <- base_params(list(
    var_mod_rows = list(c("UniMod:35", "15.994915", "M"), c("UniMod:1", "42.010565", "*n")),
    fixed_mod_rows = list(c("UniMod:4", "57.021464", "N")),
    extra = "--loc-factor 40\n--dynd 2"
  ))
  ch <- build_diann_chunks(p)
  expect_true("--var-mod 'UniMod:35,15.994915,M'" %in% ch)
  expect_true("--fixed-mod 'UniMod:4,57.021464,N'" %in% ch)
  expect_true(tail(ch, 1) == "--loc-factor 40 --dynd 2")  # 多行额外参数压缩为单行一个元素
})

test_that("gen_spec_lib 且 out_lib 留空时自动落到输出目录", {
  p <- base_params(list(gen_spec_lib = TRUE, fasta_search = TRUE, out_lib = ""))
  ch <- build_diann_chunks(p)
  expect_true(any(grepl("--out-lib '/o/library.speclib'", ch, fixed = TRUE)))
})

test_that("模板不变量: cpus-per-task 来自 threads, rcfile 落盘, 无 final_rc 覆盖, 诚实退出", {
  s <- make_slurm_script(base_params())
  expect_match(s, "#SBATCH --cpus-per-task=16", fixed = TRUE)
  expect_match(s, "printf '%s' \"$rc\" > '/o/diann_gui_scripts/diann_test.rc'", fixed = TRUE)
  expect_false(grepl("final_rc", s))
  expect_match(s, "exit $rc", fixed = TRUE)
  expect_false(grepl("-s '/o/report.tsv'", s, fixed = TRUE))  # 旧 -s 成功判定已删
})

test_that("预览模式 (无 script_path) 用占位 rc 路径; time_h NA 不限时", {
  p <- base_params(list(script_path = NULL, time_h = NA_real_))
  s <- make_slurm_script(p)
  expect_match(s, "diann_gui_preview.rc", fixed = TRUE)
  expect_false(grepl("#SBATCH -t", s, fixed = TRUE))
})

test_that("时限按分钟取整: 1.9h -> 114, 0.5h -> 30, 0.25h -> 15", {
  expect_match(make_slurm_script(base_params(list(time_h = 1.9))), "#SBATCH -t 114", fixed = TRUE)
  expect_match(make_slurm_script(base_params(list(time_h = 0.5))), "#SBATCH -t 30", fixed = TRUE)
  expect_match(make_slurm_script(base_params(list(time_h = 0.25))), "#SBATCH -t 15", fixed = TRUE)
  expect_match(make_slurm_script(base_params(list(time_h = 12))), "#SBATCH -t 720", fixed = TRUE)
})

test_that("空污染物标签回退 cRAP- (textInput 清空时是 \"\" 而非 NULL)", {
  p <- base_params(list(cont_exclude = TRUE, cont_tag = ""))
  ch <- build_diann_chunks(p)
  expect_true(any(grepl("--cont-quant-exclude 'cRAP-'", ch, fixed = TRUE)))
  p2 <- base_params(list(cont_exclude = TRUE, cont_tag = "  "))
  expect_true(any(grepl("--cont-quant-exclude 'cRAP-'", build_diann_chunks(p2), fixed = TRUE)))
})

test_that("未勾选 gen_spec_lib 时不输出 --out-lib", {
  p <- base_params(list(gen_spec_lib = FALSE, out_lib = "/d/x.speclib"))
  expect_false(any(grepl("--out-lib", build_diann_chunks(p), fixed = TRUE)))
  p2 <- base_params(list(gen_spec_lib = TRUE, out_lib = "/d/x.speclib"))
  expect_true(any(grepl("--out-lib '/d/x.speclib'", build_diann_chunks(p2), fixed = TRUE)))
})

test_that("SLURM_EXTRA_ARGS 逐行写成 #SBATCH 选项", {
  old <- diann.gui::cfg_get("SLURM_EXTRA_ARGS")
  on.exit(diann.gui::set_core_const("SLURM_EXTRA_ARGS", old), add = TRUE)
  diann.gui::set_core_const("SLURM_EXTRA_ARGS", c("--account=lab", "--qos=normal"))
  s <- make_slurm_script(base_params())
  expect_match(s, "#SBATCH --account=lab\n#SBATCH --qos=normal", fixed = TRUE)
  diann.gui::set_core_const("SLURM_EXTRA_ARGS", character(0))
  expect_false(grepl("--account=lab", make_slurm_script(base_params()), fixed = TRUE))
})

# ---------- v1.12: Slurm 脚本保持原样 / 本地脚本共用程序体 ----------

test_that("make_slurm_script 头部保持 v1.11 逐字节契约 (Slurm 模式界面/脚本不变)", {
  expected <- paste0(
    "#!/bin/bash\n",
    "#SBATCH -J 'T'\n",
    "#SBATCH -p compute\n",
    "#SBATCH --nodes=1\n",
    "#SBATCH --cpus-per-task=16\n",
    "#SBATCH --mem=64G\n",
    "#SBATCH -t 720\n",
    "#SBATCH -o '/o/slurm-%j.out'\n",
    "#SBATCH -e '/o/slurm-%j.err'\n",
    "\n\n")
  expect_identical(slurm_script_header(base_params()), expected)
  expect_identical(make_slurm_script(base_params()), paste0(expected, job_body(base_params(), "slurm")))
})

test_that("make_local_script: 无 #SBATCH / 本地头含时限 / 忽略 SLURM_EXTRA_ARGS / 共用 job_body", {
  old <- diann.gui::cfg_get("SLURM_EXTRA_ARGS")
  on.exit(diann.gui::set_core_const("SLURM_EXTRA_ARGS", old), add = TRUE)
  diann.gui::set_core_const("SLURM_EXTRA_ARGS", c("--account=lab", "--qos=normal"))
  p <- base_params(list(time_h = 1.9))
  loc <- make_local_script(p)
  expect_false(grepl("#SBATCH", loc, fixed = TRUE))
  expect_false(grepl("--account=lab", loc, fixed = TRUE))
  expect_match(loc, "#!/bin/bash\n# diann.gui 本地执行脚本 (无 Slurm)", fixed = TRUE)
  expect_match(loc, "# 时限: 114 分钟 (由运行器 timeout 强制执行)", fixed = TRUE)
  expect_match(loc, "printf '%s' \"$rc\" > '/o/diann_gui_scripts/diann_test.rc'", fixed = TRUE)
  expect_match(loc, "exit $rc", fixed = TRUE)

  # 共用同一段程序体: 从 APPTAINER_BIN= 起到结尾除"调度态"措辞外完全一致
  body_of <- function(s) {
    l <- strsplit(s, "\n", fixed = TRUE)[[1]]
    paste(l[grep("^APPTAINER_BIN=", l)[1]:length(l)], collapse = "\n")
  }
  bl <- body_of(loc)
  bs <- body_of(make_slurm_script(p))
  expect_identical(sub("本地进程态", "Slurm 终态", bl, fixed = TRUE), bs)

  # 时限留空 = 不限
  loc_na <- make_local_script(base_params(list(time_h = NA_real_)))
  expect_match(loc_na, "# 时限: 不限", fixed = TRUE)
})

test_that("make_job_script 按后端分派 (默认 slurm; local 与预览一致)", {
  p <- base_params(list(time_h = 0.25))
  expect_identical(make_job_script(p, "local"), make_local_script(p))
  expect_identical(make_job_script(p, "slurm"), make_slurm_script(p))
  expect_identical(make_job_script(p), make_slurm_script(p))
  expect_match(make_local_script(p), "# 时限: 15 分钟", fixed = TRUE)
})
