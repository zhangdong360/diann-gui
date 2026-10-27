# v1.14 结果分析·QC / 差异分析 / 报告 / 依赖检查 (绘图层, 缺包时跳过)

test_that("qc_compute: 8 张 QC 图 + 汇总统计", {
  skip_analysis_qc()
  p <- prep_run(make_fixture_pg_matrix(seed = 11), params = list())
  qc <- qc_compute(p)
  expect_setequal(
    names(qc$plots),
    c("01_qc_detected_counts", "02_qc_missingness", "03_qc_pca",
      "04_qc_correlation_heatmap", "05_qc_sample_clustering",
      "06_qc_cv_distribution", "07_qc_cv_boxplot", "08_qc_median_norm_boxplot"))
  expect_length(qc$stats$pca_var, 2)
  expect_setequal(names(qc$stats$cv_median), c("A", "B"))
  expect_s3_class(qc$stats$cv_summary, "data.frame")
  expect_true(all(qc$stats$cor_range >= -1 & qc$stats$cor_range <= 1))
})

test_that("qc_compute: 完全检出蛋白不足时降级并告警", {
  skip_analysis_qc()
  # 不插补 + 确定性缺失: 前 10 个蛋白各缺 1 列 => 完全检出行仅 2 个 (<3)
  set.seed(9)
  m <- 2 ^ matrix(rnorm(12 * 6, 20, 0.3), nrow = 12)
  for (i in seq_len(10)) m[i, (i %% 6) + 1] <- NA_real_
  df <- data.frame(
    Protein.Group = sprintf("P%02d_HUMAN", seq_len(12)),
    Protein.Names = sprintf("Protein_%02d_HUMAN", seq_len(12)),
    PG.Genes = paste0("GENE", seq_len(12)),
    First.Protein.Description = sprintf("Protein_%02d (Homo sapiens)", seq_len(12)),
    m, check.names = FALSE, stringsAsFactors = FALSE)
  colnames(df)[5:10] <- c("A1", "A2", "A3", "B1", "B2", "B3")
  p <- prep_run(df, params = list(impute_method = "none"))
  qc <- qc_compute(p)
  expect_false("03_qc_pca" %in% names(qc$plots))
  expect_true(any(grepl("不足 3 个", qc$warnings)))
  expect_true(any(grepl("未做缺失值插补", qc$warnings)))
})

test_that("qc_save_all: SVG 落盘", {
  skip_analysis_qc(); skip_if_not_installed("svglite")
  p <- prep_run(make_fixture_pg_matrix(seed = 13), params = list())
  qc <- qc_compute(p)
  out <- file.path(tempdir(), sprintf("anqc_%d", as.integer(Sys.time())))
  dir.create(out, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  files <- qc_save_all(qc, out)
  expect_true(all(file.exists(file.path(out, paste0(names(qc$plots), ".svg")))))
  expect_true(length(files) >= 8)
})

test_that("median_norm_boxplot / missing_profile_plots: 返回 new_plot 对象", {
  skip_analysis_qc()
  p <- prep_run(make_fixture_pg_matrix(seed = 17), params = list())
  b <- median_norm_boxplot(p)
  expect_identical(b$kind, "grid")
  mp <- missing_profile_plots(p)
  expect_identical(names(mp$plots), c("A", "B"))
  expect_true(is.finite(mp$stats$rho))
})

test_that("de_compute: 单对比回收设计差异蛋白 (B vs A, 上调 fold=4)", {
  skip_analysis_de()
  df <- make_fixture_pg_matrix(n_prot = 40, n_eff = 12, fold = 4, seed = 42)
  p <- prep_run(df, params = list(impute_method = "mnar"))
  de <- de_compute(p, logFC_cutoff = 1, pval_cutoff = 0.05)
  expect_identical(de$mode, "single")
  pt <- de$pairs[[1]]
  expect_identical(pt$contrast, "B vs A")
  # 前 12 个设计上调蛋白应大部分被检出 (允许个别受噪声/插补影响)
  eff_pg <- sprintf("P%03d_HUMAN", seq_len(12))
  recovered <- intersect(eff_pg, pt$sig$Protein.Group)
  expect_gte(length(recovered), 8)
  expect_true(all(pt$sig$logFC[match(recovered, pt$sig$Protein.Group)] > 0))
  expect_gte(pt$sig_up, 8)
  # 结果表列结构
  expect_setequal(colnames(pt$res),
                  c("Protein.Group", "Genes", "Protein.Names", "Description",
                    "logFC", "AveExpr", "t", "P.Value", "adj.P.Val", "Significant"))
  # 图形对象
  expect_setequal(names(pt$plots),
                  c("09_diff_volcano", "10_diff_heatmap", "11_diff_count_barplot",
                    "12_diff_top_protein_boxplot"))
})

test_that("de_compute: 多组模式 (全局 F + 两两对比)", {
  skip_analysis_de()
  df <- make_fixture_pg_matrix(n_prot = 24, groups = c("A", "B", "C"), seed = 19)
  p <- prep_run(df, params = list())
  de <- de_compute(p)
  expect_identical(de$mode, "multi")
  expect_false(is.null(de$anova))
  expect_identical(nrow(de$pair_stat), 3L)   # C(3,2) = 3 个两两对比
  expect_identical(de$anova$ref, "A")
  # 各对比 tag 可作文件名 (安全化)
  expect_true(all(grepl("^[A-Za-z0-9._-]+_vs_[A-Za-z0-9._-]+$", de$pair_stat$FileTag)))
})

test_that("de_compute: 非法组名安全化后仍可计算", {
  skip_analysis_de()
  df <- make_fixture_pg_matrix(groups = c("A", "B"), seed = 23)
  colnames(df)[7:12] <- c("1组 A1", "1组 A2", "1组 A3", "2组 B1", "2组 B2", "2组 B3")
  gm <- data.frame(Sample = colnames(df)[7:12],
                   Group = rep(c("ctrl 组", "处理组"), each = 3),
                   stringsAsFactors = FALSE)
  p <- prep_run(df, params = list(), sample_group_map = gm)
  de <- de_compute(p)
  expect_identical(de$mode, "single")
  expect_gte(nrow(de$pairs[[1]]$sig), 0)
})

test_that("de_stem / safe_tag: 文件名安全化", {
  expect_identical(de_stem("04_res.csv", ""), "04_res.csv")
  expect_identical(de_stem("04_res.csv", "B_vs_A"), "04_res_B_vs_A.csv")
  expect_identical(de_stem("04_res", "B_vs_A"), "04_res_B_vs_A")
  # ASCII 保留, 非 [A-Za-z0-9._-] 逐字符替换为 _
  expect_identical(safe_tag("B vs/A"), "B_vs_A")
  expect_identical(safe_tag("G1.2-x"), "G1.2-x")
  expect_identical(safe_tag("组1"), "_1")
})

test_that("de_save_all: 表格与图形落盘 (含 xlsx)", {
  skip_analysis_de(); skip_if_not_installed("svglite"); skip_if_not_installed("openxlsx")
  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  de <- de_compute(p)
  out <- file.path(tempdir(), sprintf("ande_%d", as.integer(Sys.time())))
  dir.create(out, showWarnings = FALSE, recursive = TRUE)
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  files <- de_save_all(de, out)
  expect_true(file.exists(file.path(out, "04_de_limma_results_all.csv")))
  expect_true(file.exists(file.path(out, "04_05_de_limma_results.xlsx")))
  expect_true(file.exists(file.path(out, "09_diff_volcano.svg")))
})

test_that("report_build: 完整报告目录契约 (qc+de)", {
  skip_analysis_report()
  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  qc <- qc_compute(p)
  de <- de_compute(p)
  out_root <- file.path(tempdir(), sprintf("anrep_%d", as.integer(Sys.time())))
  on.exit(unlink(out_root, recursive = TRUE), add = TRUE)
  params <- list(source = "diann", de_logFC_cutoff = 1, de_pval_cutoff = 0.05,
                 de_p_adjust_method = "BH", enrich_use_kegg = FALSE)
  res <- report_build(out_root, p, qc, de, NULL, params, modules = c("qc", "de"))
  # 目录/主文件
  expect_true(file.exists(res$html))
  expect_match(basename(res$dir), "^analysis_report_[0-9]{8}_[0-9]{6}$")
  html <- paste(readLines(res$html, warn = FALSE), collapse = "\n")
  expect_match(html, "1 项目概述", fixed = TRUE)
  expect_match(html, "3 差异蛋白分析", fixed = TRUE)
  expect_match(html, "未执行功能富集模块", fixed = TRUE)
  expect_match(html, "./assets/style.css", fixed = TRUE)
  # 产物
  expect_true(file.exists(file.path(res$dir, "analysis_params.json")))
  expect_true(file.exists(file.path(res$dir, "08_summary_report.md")))
  expect_true(file.exists(file.path(res$dir, "assets", "style.css")))
  expect_true(file.exists(file.path(res$dir, "assets", "report.js")))
  expect_gt(res$n_figs, 0)
  expect_gt(res$n_tables, 0)
  # 参数 JSON 可解析
  pj <- jsonlite::fromJSON(file.path(res$dir, "analysis_params.json"))
  expect_identical(pj$mode, "single")
  expect_match(pj$species, "Homo sapiens")
  # data/ 内有 svg 与 iframe 表
  expect_true(file.exists(file.path(res$dir, "data", "dep_table.html")))
})

test_that("report_build: 仅 QC 模块时差异章节降级占位", {
  skip_analysis_report()
  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  qc <- qc_compute(p)
  out_root <- file.path(tempdir(), sprintf("anrep2_%d", as.integer(Sys.time())))
  on.exit(unlink(out_root, recursive = TRUE), add = TRUE)
  res <- report_build(out_root, p, qc, NULL, NULL, list(), modules = c("qc"))
  html <- paste(readLines(res$html, warn = FALSE), collapse = "\n")
  expect_match(html, "未执行差异分析模块", fixed = TRUE)
})

test_that("an_deps: 分组检查与安装提示", {
  df <- an_deps_check()
  labels <- vapply(an_deps_groups(), function(g) g$label, character(1))
  expect_setequal(unname(labels), unique(df$group))
  expect_setequal(colnames(df), c("pkg", "bioc", "installed", "group"))
  expect_true("limma" %in% df$pkg && df$bioc[df$pkg == "limma"])
  hint <- an_deps_install_hint(c("ggplot2", "limma"), c(FALSE, TRUE))
  expect_length(hint, 2)
  expect_match(hint[1], "install\\.packages\\(c\\(\"ggplot2\"\\)\\)")
  expect_match(hint[2], "BiocManager::install\\(c\\(\"limma\"\\)\\)")
  expect_length(an_deps_install_hint(character(0), logical(0)), 0)
  expect_setequal(names(an_deps_optional()),
                  c("sva", "impute", "KEGG.db", "org.Hs.eg.db", "org.Mm.eg.db",
                    "org.Rn.eg.db", "org.Dr.eg.db"))
})
