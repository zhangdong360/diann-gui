# v1.14 结果分析·富集层 (依赖重: clusterProfiler/org.Xx.eg.db, 缺包一律优雅跳过)

test_that("enrich_compute: 显著蛋白不足时优雅跳过 (不依赖任何重包)", {
  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  de <- list(sig = p$annot[seq_len(2), , drop = FALSE])   # 仅 2 个显著蛋白 < min_sig=5
  en <- enrich_compute(p, de)
  expect_true(en$skipped)
  expect_match(en$reason, "少于富集分析所需")
})

test_that("enrich_compute: GO/KEGG 全流程 (本地 KEGG.db) — 仅在富集依赖可用时运行", {
  skip_if_not_installed("clusterProfiler")
  skip_if_not_installed("AnnotationDbi")
  skip_if_not_installed("org.Hs.eg.db")
  skip_if_not_installed("KEGG.db")

  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  de <- de_compute(p)
  en <- enrich_compute(p, de, use_kegg = FALSE)
  expect_false(en$skipped)
  expect_identical(en$org_pkg, "org.Hs.eg.db")
  expect_true(length(en$plots) > 0 || length(en$tables) > 0)
  if (length(en$plots)) {
    expect_true(all(grepl("^13_enrichment_go_barplot_|^14_enrichment_go_dotplot",
                          names(en$plots))))
  }
})

test_that("enrich_compute: KEGG.db 缺失时降级为跳过并提示 (不联网)", {
  skip_if_not_installed("clusterProfiler")
  skip_if_not_installed("AnnotationDbi")
  skip_if_not_installed("org.Hs.eg.db")
  skip_if(requireNamespace("KEGG.db", quietly = TRUE), "本机装有 KEGG.db, 降级用例不适用")

  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  de <- de_compute(p)
  en <- enrich_compute(p, de, use_kegg = TRUE, kegg_online = FALSE)
  expect_false(en$skipped)                    # GO 仍执行, 只是 KEGG 被降级
  expect_false("KEGG" %in% names(en$sources))
  expect_true(any(grepl("KEGG.db", en$warnings)))
})

test_that("enrich_save_all: 跳过态不产出文件", {
  p <- prep_run(make_fixture_pg_matrix(seed = 42), params = list())
  en <- enrich_compute(p, list(sig = p$annot[seq_len(2), , drop = FALSE]))
  out <- file.path(tempdir(), sprintf("anen_%d", as.integer(Sys.time())))
  dir.create(out, showWarnings = FALSE)
  on.exit(unlink(out, recursive = TRUE), add = TRUE)
  expect_length(enrich_save_all(en, out), 0)
})
