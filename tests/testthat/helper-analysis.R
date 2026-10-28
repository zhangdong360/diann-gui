# v1.14 结果分析层测试公共设施: 内部函数别名 + 合成 DIA-NN pg_matrix 夹具

# 内部函数别名 (与 helper.R 同风格)
for (f in c("prep_run", "qc_compute", "de_compute", "enrich_compute",
            "report_build", "auto_annot_cols", "resolve_groups", "validate_group_map",
            "validate_batch_map", "read_input_file", "impute_missing", "detect_species",
            "qc_save_all", "de_save_all", "enrich_save_all", "de_stem", "safe_tag",
            "de_safe_levels", "an_deps_check", "an_deps_status", "an_deps_install_hint",
            "an_deps_groups", "an_deps_optional", "theme_proteo", "new_plot",
            "save_plot_obj", "median_norm_boxplot", "missing_profile_plots",
            "combat_correct", "normalize_sample_map", "infer_groups",
            "analysis_find_matrices", "kegg_enrich_run")) {
  assign(f, getFromNamespace(f, "diann.gui"))
}

# 合成 DIA-NN pg_matrix (蛋白水平定量矩阵, 列名/结构仿真实输出)
# - groups 默认 A/B 各 n_rep 个样本; 传 c("A","B","C") 可得多组
# - 前 n_eff 个蛋白在 B 组(第 2 组)上调 fold 倍 (供 DE 用例核对回收)
# - 尾部 2 条污染条目: REV_ 反库 + 描述含 Contaminant 的 cRAP (供过滤用例核对)
# - 缺失按 MNAR 模式撒: 低丰度 1/3 蛋白缺失率高、其余低 (贴近真实 DIA 数据,
#   与 LoD 插补的适用场景一致), 保证每行每列至少 1 个观测
make_fixture_pg_matrix <- function(n_prot = 40, n_rep = 3, groups = c("A", "B"),
                                   n_eff = 12, fold = 4, seed = 42) {
  set.seed(seed)
  gl <- match.arg(groups, choices = as.character(c("A", "B", "C")),
                  several.ok = TRUE)
  snames <- unlist(lapply(gl, function(g) paste0(g, seq_len(n_rep))))
  gvec   <- rep(gl, each = n_rep)
  base   <- 2 ^ stats::rnorm(n_prot, mean = 20, sd = 1)   # ~1e6 线性强度
  eff    <- rep(1, n_prot)
  eff[seq_len(min(n_eff, n_prot))] <- fold                # 在第 2 组 (B) 上调
  m <- sapply(snames, function(s) {
    mult <- if (gvec[match(s, snames)] == gl[2]) eff else 1
    base * mult * 2 ^ stats::rnorm(n_prot, 0, 0.15)
  })
  # MNAR 缺失: 低丰度 1/3 蛋白缺失率高 (0.12), 其余 0.02
  p_miss <- rep(0.02, n_prot)
  p_miss[order(base)[seq_len(max(1L, n_prot %/% 3))]] <- 0.12
  idx <- which(matrix(stats::runif(n_prot * ncol(m)), nrow = n_prot) < p_miss)
  m[idx] <- NA_real_
  for (i in seq_len(nrow(m))) if (all(is.na(m[i, ]))) m[i, sample(ncol(m), 1)] <- base[i]
  for (j in seq_len(ncol(m))) if (all(is.na(m[, j]))) m[sample(nrow(m), 1), j] <- 1e6

  pg  <- sprintf("P%03d_HUMAN", seq_len(n_prot))
  desc <- sprintf("Protein_%03d (Homo sapiens)", seq_len(n_prot))
  pg[n_prot]     <- "cRAP_ALBU_HUMAN"               # 污染 (描述含 Contaminant)
  desc[n_prot]   <- "Albumin (Contaminant)"
  pg[n_prot - 1] <- paste0("REV_", pg[n_prot - 1])  # 反库
  data.frame(
    Protein.Group             = pg,
    Protein.Names             = sprintf("Protein_%03d_HUMAN", seq_len(n_prot)),
    PG.Genes                  = paste0("GENE", seq_len(n_prot)),
    First.Protein.Description = desc,
    N.Sequences               = sample(2:20, n_prot, replace = TRUE),
    N.Proteotypic.Sequences   = sample(1:10, n_prot, replace = TRUE),
    m,
    check.names = FALSE, stringsAsFactors = FALSE)
}

# 夹具写盘 (tsv) 供 read_input_file / 端到端用例
write_fixture_matrix <- function(df, path) {
  utils::write.table(df, path, sep = "\t", quote = FALSE, row.names = FALSE,
                     na = "NA")
  path
}

# 分析层依赖的 skip 条件 (缺包时优雅跳过, CI 不装 Bioconductor 重包)
skip_analysis_qc <- function() {
  skip_if_not_installed("ggplot2"); skip_if_not_installed("ggrepel")
  skip_if_not_installed("gridExtra"); skip_if_not_installed("pheatmap")
  skip_if_not_installed("scales")
}
skip_analysis_de <- function() {
  skip_analysis_qc(); skip_if_not_installed("limma")
}
skip_analysis_report <- function() {
  skip_analysis_de(); skip_if_not_installed("svglite"); skip_if_not_installed("openxlsx")
}
