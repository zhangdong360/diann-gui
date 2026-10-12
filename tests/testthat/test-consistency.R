# 类别级不变量: 命令构建↔解析往返 + 旗标映射↔UI/重置控件交叉核对
# 目的: 把"新加旗标漏改映射/reset/UI 之一"这类漂移在 CI 拦下, 而不是等生产事故

test_that("build -> parse 往返: 全部映射旗标语义等价, 无未知/裸旗标残留", {
  bools <- setdiff(names(BOOL_FLAG_MAP), "--convert")  # convert 单独分支
  p <- base_params(list(
    raws = c(), fastas = "/d/db.fasta", lib = "/d/in.speclib",
    ref = "/d/ref.speclib", temp = "/t", out_dir = "/o", out_file = "/o/report.tsv",
    use_cut = TRUE, cut = "K*,R*", convert_only = FALSE, cont_exclude = FALSE,
    extra = "", gen_spec_lib = TRUE, out_lib = "",
    var_mod_rows = list(c("UniMod:35", "15.994915", "M")),
    fixed_mod_rows = list(c("UniMod:4", "57.021464", "N")),
    qvalue = 0.01, threads = 16, verbose = 1L,
    mass_acc = 4.5, mass_acc_ms1 = 8, window = 0.5, min_peak = 100,
    rt_window = 180, im_window = 3, quant_qvalue = 0.02,
    protein_quant_qvalue = 0.05, matrix_qvalue = 0.1, var_mods_max = 3,
    missed_cleavages = 2, min_pep_len = 7, max_pep_len = 30,
    min_pr_mz = 350, max_pr_mz = 1250, min_pr_charge = 2, max_pr_charge = 5,
    min_fr_mz = 200, max_fr_mz = 1800, out_lib_qvalue = 0.03, xic = 60,
    min_corr = 0.5
  ))
  for (flag in bools) {
    id <- unname(BOOL_FLAG_MAP[[flag]])
    # params_ready 的字段名: inputId mbr 对应字段 reanalyse, 其余同名
    p[[if (id == "mbr") "reanalyse" else id]] <- TRUE
  }

  cmd <- paste(build_diann_chunks(p), collapse = " ")
  r <- parse_diann_command(cmd)

  # 布尔: 构建出的全部识别, 且恰好是映射集合 (convert 除外)
  expect_setequal(r$bool, bools)
  # 数值: 25 个旗标全部往返一致
  expect_setequal(names(r$num), names(NUM_FLAG_MAP))
  for (flag in names(NUM_FLAG_MAP)) {
    expect_equal(r$num[[flag]], as.numeric(p[[unname(NUM_FLAG_MAP[[flag]])]]),
                 info = flag)
  }
  # 文本与文件位
  expect_equal(r$text[["--cut"]], "K*,R*")
  expect_equal(r$files$lib, "/d/in.speclib")
  expect_equal(r$files$ref, "/d/ref.speclib")
  expect_equal(r$files$temp, "/t")
  # --out 拆解为输出目录 + 报告名
  expect_equal(r$files$out_dir, "/o")
  expect_equal(r$report_name, "report")
  # gen_spec_lib 且 out_lib 留空: 构建自动落 <out_dir>/library.speclib
  expect_equal(r$text[["--out-lib"]], "/o/library.speclib")
  # 修饰行往返
  expect_equal(r$var_mods[[1]], c("UniMod:35", "15.994915", "M"))
  expect_equal(r$fixed_mods[[1]], c("UniMod:4", "57.021464", "N"))
  # 构建端永不产生未知/裸旗标 (一旦出现即映射缺失)
  expect_length(r$unknown, 0)
  expect_length(r$bare, 0)
})

test_that("三方交叉核对: 映射里的每个 inputId 都在应用源码中出现", {
  sources <- list.files(PROJECT_ROOT, pattern = "\\.R$", full.names = TRUE)
  src <- paste(vapply(sources, function(f) paste(readLines(f, warn = FALSE), collapse = "\n"), ""), collapse = "\n")
  ids <- unname(c(BOOL_FLAG_MAP, NUM_FLAG_MAP, TEXT_FLAG_MAP))
  for (id in ids) {
    expect_true(grepl(paste0('"', id, '"'), src),
                info = paste("映射值", id, "在应用源码中找不到对应控件"))
  }
})

test_that("reset_import_state 的数值重置清单 = 数值映射 - 约定例外", {
  src <- paste(readLines(file.path(PROJECT_ROOT, "app.R"), warn = FALSE), collapse = "\n")
  m <- regmatches(src, regexpr(
    'for \\(ctrl in c\\([^)]*\\)\\)\\s*\\{?\\s*updateNumericInput\\(session, ctrl, value = NA\\)',
    src))[[1]]
  reset_ids <- parse(text = sub(".*for \\(ctrl in c\\(([^)]*)\\)\\).*", "c(\\1)", m))[[1]]
  reset_ids <- as.character(eval(reset_ids))
  # threads sticky / verbose 特殊 / var_mods_max 单独重置, 是文档化例外
  expect_setequal(reset_ids, setdiff(unname(NUM_FLAG_MAP),
                                     c("threads", "verbose", "var_mods_max")))
})

test_that("PATH_VALUE_FLAGS 全部可作为裸旗标被识别记录", {
  cmd <- paste("diann", paste(PATH_VALUE_FLAGS, collapse = " "))
  r <- parse_diann_command(cmd)
  expect_setequal(r$bare, PATH_VALUE_FLAGS)
  expect_length(r$unknown, 0)
})
