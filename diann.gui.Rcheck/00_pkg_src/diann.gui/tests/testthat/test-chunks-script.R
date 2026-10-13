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
