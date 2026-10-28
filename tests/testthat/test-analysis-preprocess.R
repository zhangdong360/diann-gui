# v1.14 结果分析·预处理层: 注释列识别 / 读取 / 分组校验 / prep_run 流程

test_that("auto_annot_cols: DIA-NN pg_matrix 注释列识别与样本列划分", {
  df <- make_fixture_pg_matrix()
  am <- auto_annot_cols(colnames(df), "diann")
  expect_identical(am$Protein.Group, "Protein.Group")
  expect_identical(am$Genes, "PG.Genes")
  expect_identical(am$N.Sequences, "N.Sequences")
  expect_true(is.na(am$Organism))
  sample_cols <- setdiff(colnames(df), unlist(am[!is.na(unlist(am))]))
  expect_setequal(sample_cols, c("A1", "A2", "A3", "B1", "B2", "B3"))
})

test_that("auto_annot_cols: Spectronaut PG.* 列识别", {
  cn <- c("PG.ProteinAccessions", "PG.ProteinNames", "PG.Genes",
          "PG.ProteinDescriptions", "PG.Organisms", "S1", "S2", "S3", "S4")
  am <- auto_annot_cols(cn, "spectronaut")
  expect_identical(am$Protein.Group, "PG.ProteinAccessions")
  expect_identical(am$Organism, "PG.Organisms")
  expect_setequal(setdiff(cn, unlist(am[!is.na(unlist(am))])), c("S1", "S2", "S3", "S4"))
})

test_that("read_input_file: tsv 与 csv 分隔符自判", {
  df <- make_fixture_pg_matrix(n_prot = 8)
  tsv <- write_fixture_matrix(df, file.path(tempdir(), "anfix_tsv.tsv"))
  on.exit(unlink(tsv), add = TRUE)
  d1 <- read_input_file(tsv)
  expect_identical(colnames(d1)[1], "Protein.Group")
  expect_equal(nrow(d1), 8)

  csv <- file.path(tempdir(), "anfix_csv.csv")
  utils::write.csv(df, csv, row.names = FALSE)
  on.exit(unlink(csv), add = TRUE)
  d2 <- read_input_file(csv)
  expect_identical(colnames(d2)[1], "Protein.Group")
})

test_that("validate_group_map: 空/缺列/单组/单样本给出中文原因", {
  expect_match(validate_group_map(NULL), "为空")
  expect_match(validate_group_map(data.frame(Sample = "A1", Group = "A")),
               "至少需要 2 个分组")
  bad <- data.frame(Sample = c("A1", "A2", "B1"), Group = c("A", "A", "B"))
  expect_match(validate_group_map(bad), "仅 1 个样本")
  ok <- data.frame(Sample = c("A1", "A2", "B1", "B2"), Group = c("A", "A", "B", "B"))
  expect_null(validate_group_map(ok))
})

test_that("prep_run: 过滤/插补/归一化/分组 全流程数值正确", {
  df <- make_fixture_pg_matrix(n_prot = 30, n_rep = 3, fold = 4, seed = 42)
  p <- prep_run(df, params = list(source = "diann", min_detect_frac = 0.5,
                                  impute_method = "mnar"))
  # 污染/反库: 2 条
  expect_identical(p$n_contam, 2L)
  # 自动分组 A/B 各 3 个
  expect_identical(p$group_levels, c("A", "B"))
  expect_identical(p$map_src, "auto")
  # 插补后矩阵无缺失
  expect_false(anyNA(p$expr_imp))
  # 归一化: 各样本中位数对齐到最大值
  meds <- apply(p$expr_imp, 2, stats::median)
  expect_equal(max(meds), p$median_target, tolerance = 1e-8)
  expect_true(all(abs(meds - p$median_target) < 1e-6))
  # 对照组默认第一组; 物种自动检测为 Human
  expect_identical(p$control_grp, "A")
  expect_match(p$species, "Homo sapiens")
  # 检出数向量长度 = 样本数
  expect_identical(length(p$det_sample), 6L)
  expect_identical(ncol(p$expr_imp), 6L)
})

test_that("prep_run: impute_method=none 保留缺失并标记未插补", {
  df <- make_fixture_pg_matrix(seed = 7)
  p <- prep_run(df, params = list(impute_method = "none"))
  expect_false(p$imputed)
  expect_true(anyNA(p$expr_imp))
  expect_true(any(grepl("不填补", p$warnings)))
})

test_that("prep_run: 显式分组表生效 (explicit 模式)", {
  df <- make_fixture_pg_matrix(seed = 3)
  gm <- data.frame(Sample = c("A1", "A2", "A3", "B1", "B2", "B3"),
                   Group = c("G1", "G1", "G1", "G2", "G2", "G2"),
                   stringsAsFactors = FALSE)
  p <- prep_run(df, params = list(), sample_group_map = gm)
  expect_identical(p$group_levels, c("G1", "G2"))
  expect_identical(p$map_src, "explicit")
})

test_that("prep_run: 分组表未覆盖样本列时报错", {
  df <- make_fixture_pg_matrix(seed = 3)
  gm <- data.frame(Sample = c("A1", "A2", "B1", "B2"),
                   Group = c("G1", "G1", "G2", "G2"), stringsAsFactors = FALSE)
  expect_error(prep_run(df, params = list(), sample_group_map = gm), "未被分组表覆盖")
})

test_that("detect_species: UniProt 后缀与默认回退", {
  a <- data.frame(Protein.Names = "X_HUMAN", First.Protein.Description = "",
                  Organism = NA_character_)
  expect_identical(detect_species(a)$org_pkg, "org.Hs.eg.db")
  b <- data.frame(Protein.Names = "X_MOUSE", First.Protein.Description = "",
                  Organism = NA_character_)
  expect_identical(detect_species(b)$kegg_org, "mmu")
  c <- data.frame(Protein.Names = "NoName", First.Protein.Description = "unknown",
                  Organism = NA_character_)
  sp <- detect_species(c)
  expect_match(sp$species, "default")
  expect_true(!is.null(sp$warn))
})

# v1.14.1: 全缺失样本列硬阻断 (此前 NaN 插补带病进入 limma)
test_that("prep_run: 全缺失样本列硬阻断并点名样本", {
  df <- make_fixture_pg_matrix(n_prot = 30, seed = 21)
  df[["B3"]] <- NA_real_          # 整列清空 (零检出样本)
  err <- tryCatch(prep_run(df, params = list(source = "diann", min_detect_frac = 0.5,
                                             impute_method = "mnar")),
                  error = function(e) e)
  expect_s3_class(err, "error")
  expect_match(conditionMessage(err), "全缺失", fixed = TRUE)
  expect_match(conditionMessage(err), "B3", fixed = TRUE)
  # 部分缺失 (非全缺) 不受影响
  df2 <- make_fixture_pg_matrix(n_prot = 30, seed = 21)
  df2[["B3"]][seq_len(10)] <- NA_real_
  p2 <- prep_run(df2, params = list(source = "diann", min_detect_frac = 0.5,
                                    impute_method = "mnar"))
  expect_false(anyNA(p2$expr_imp))
})

# ---------- v1.14.1: ComBat 数值回归 (此前无任何数值测试) ----------

test_that("combat_correct: 批次效应去除且组间差异保留 (数值)", {
  skip_if_not_installed("sva")
  set.seed(7)
  n_prot <- 200
  grp   <- c(rep("A", 4), rep("B", 4))
  batch <- c("b1", "b2", "b1", "b2", "b1", "b2", "b1", "b2")
  base  <- 2 ^ stats::rnorm(n_prot, 20, 1)
  eff   <- rep(1, n_prot); eff[seq_len(50)] <- 4   # B 组上调 log2FC=2
  m <- sapply(seq_len(8), function(i) {
    g <- if (grp[i] == "B") eff else 1
    b <- if (batch[i] == "b2") 2 else 1             # 批次效应 log2FC=1 (加性)
    base * g * b * 2 ^ stats::rnorm(n_prot, 0, 0.1)
  })
  ml <- log2(m)
  res <- combat_correct(ml, batch, grp)
  expect_true(res$ok)
  out <- as.matrix(res$mat)
  # ① 批次效应去除: 仅看 A 组 (组效应不受混杂), b2-b1 的逐蛋白差异中位数从 ~1 降到 ~0
  iA <- grp == "A"
  bef <- stats::median(apply(ml[, iA], 1, function(v) diff(tapply(v, batch[iA], mean))))
  aft <- stats::median(apply(out[, iA], 1, function(v) diff(tapply(v, batch[iA], mean))))
  expect_gt(abs(bef), 0.5)
  expect_lt(abs(aft), 0.2)
  # ② 组间效应保留: 设计效应蛋白 B-A 中位 log2FC 仍接近 2, 非效应蛋白接近 0
  fc <- rowMeans(out[, grp == "B"]) - rowMeans(out[, grp == "A"])
  expect_gt(stats::median(fc[seq_len(50)]), 1.5)
  expect_lt(abs(stats::median(fc[51:n_prot])), 0.3)
})

test_that("combat_correct: <2 批次 / 含缺失 / 完全混淆 拒绝执行并给原因", {
  skip_if_not_installed("sva")
  m <- matrix(stats::rnorm(20), nrow = 5)
  r1 <- combat_correct(m, rep("b1", 5), NULL)
  expect_false(r1$ok); expect_match(r1$reason, "批次")
  r2 <- combat_correct(`[<-`(m, 1, 1, value = NA), c("b1", "b2", "b1", "b2", "b1"), NULL)
  expect_false(r2$ok); expect_match(r2$reason, "缺失")
  r3 <- combat_correct(m, c("b1", "b1", "b1", "b1", "b2"),
                       c("A", "A", "A", "A", "B"))   # 批次与分组完全混淆
  expect_false(r3$ok); expect_match(r3$reason, "完全混杂")
})
