# ============================================================
# analysis-preprocess.R — 结果分析·预处理核心 (移植自 mass_analysis/core_preprocess.R)
# 数据读取 / 清洗 / 过滤 / log2 / 插补 / 归一化 (纯函数, 返回 prep 对象)
# 流程: 读取 -> 过滤 -> log2 -> 插补 -> 样本中位数归一化 -> 可选 ComBat
# ============================================================

# ---- 注释列识别 (source: diann / spectronaut; 输出统一的规范列名) ----
auto_annot_cols <- function(cn, source = "diann") {
  if (is.null(source) || length(source) != 1L || is.na(source) || !nzchar(source))
    source <- "diann"
  source <- match.arg(source, c("diann", "spectronaut"))
  classes <- switch(
    source,
    diann = list(
      Protein.Group             = "Protein\\.Group|ProteinAccessions|Accessions$",
      Protein.Names             = "Protein\\.Names",
      Genes                     = "PG\\.Genes|\\.Genes$|^Genes$",
      First.Protein.Description = "First\\.Protein\\.Description|^Description$",
      Organism                  = "^$",   # DIA-NN pg_matrix 无该列 (物种靠 _HUMAN 等后缀判定)
      N.Sequences               = "^N\\.Sequences$",
      N.Proteotypic.Sequences   = "^N\\.Proteotypic\\.Sequences$"),
    spectronaut = list(
      Protein.Group             = "PG\\.ProteinAccessions|PG\\.ProteinGroups",
      Protein.Names             = "PG\\.ProteinNames",
      Genes                     = "PG\\.Genes",
      First.Protein.Description = "PG\\.ProteinDescriptions",
      Organism                  = "PG\\.Organisms",
      N.Sequences               = "^$",
      N.Proteotypic.Sequences   = "^$"))
  taken <- character(0)
  out <- lapply(names(classes), function(nm) {
    pat <- classes[[nm]]
    if (is.null(pat) || length(pat) != 1L || is.na(pat) || !nzchar(pat)) return(NA_character_)
    cand <- cn[!cn %in% taken]
    hit  <- cand[grepl(pat, cand, ignore.case = TRUE)]
    if (length(hit) == 0) return(NA_character_)
    hit <- hit[1]
    taken <<- c(taken, hit)
    hit
  })
  names(out) <- names(classes)
  out
}

# ---- 样本->组 映射规范化 (NULL / data.frame / 命名 list) ----
normalize_sample_map <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.data.frame(x)) {
    m <- x[, intersect(c("Sample", "Group"), colnames(x)), drop = FALSE]
  } else if (is.list(x)) {
    m <- data.frame(Sample = unlist(x, use.names = FALSE),
                    Group  = rep(names(x), lengths(x)),
                    stringsAsFactors = FALSE)
  } else {
    stop("sample_group_map 须为 NULL / data.frame(Sample,Group) / 命名 list")
  }
  if (!identical(colnames(m), c("Sample", "Group")))
    stop("sample_group_map 必须包含 Sample 与 Group 两列")
  m <- m[!is.na(m$Sample) & !is.na(m$Group) & m$Sample != "" & m$Group != "", , drop = FALSE]
  if (anyDuplicated(m$Sample))
    stop("sample_group_map 中存在重复的 Sample: ",
         paste(m$Sample[duplicated(m$Sample)], collapse = ", "))
  if (nrow(m) == 0) stop("sample_group_map 为空, 请检查填写内容")
  m
}

# ---- 分组校验: 返回 NULL 或中文原因; 界面与编排层共用 ----
validate_group_map <- function(df) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) return("分组表为空。")
  if (!all(c("Sample", "Group") %in% colnames(df))) return("分组表缺少 Sample / Group 列。")
  g <- trimws(as.character(df$Group))
  if (any(is.na(g) | g == "")) return("存在空组名。")
  tb <- table(g)
  if (length(tb) < 2) return("至少需要 2 个分组。")
  if (any(tb < 2))
    return(sprintf("每个分组至少需要 2 个样本；当前 %s 组仅 1 个样本。",
                   paste(names(tb)[tb < 2], collapse = ", ")))
  NULL
}

# ---- 样本->批次 映射 (同分组表) ----
normalize_batch_map <- function(x) {
  if (is.null(x)) return(NULL)
  if (is.data.frame(x)) {
    m <- x[, intersect(c("Sample", "Batch"), colnames(x)), drop = FALSE]
  } else if (is.list(x)) {
    m <- data.frame(Sample = unlist(x, use.names = FALSE),
                    Batch  = rep(names(x), lengths(x)),
                    stringsAsFactors = FALSE)
  } else {
    stop("sample_batch_map 须为 NULL / data.frame(Sample,Batch) / 命名 list")
  }
  if (!identical(colnames(m), c("Sample", "Batch")))
    stop("sample_batch_map 必须包含 Sample 与 Batch 两列")
  m <- m[!is.na(m$Sample) & !is.na(m$Batch) & m$Sample != "" & m$Batch != "", , drop = FALSE]
  if (anyDuplicated(m$Sample))
    stop("sample_batch_map 中存在重复的 Sample: ",
         paste(m$Sample[duplicated(m$Sample)], collapse = ", "))
  if (nrow(m) == 0) stop("sample_batch_map 为空, 请检查填写内容")
  m
}

# ---- 批次校验: 批次名非空、>=2 批、每批 >=2 样本 ----
validate_batch_map <- function(df, snames = NULL) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) == 0) return("批次表为空。")
  if (!all(c("Sample", "Batch") %in% colnames(df))) return("批次表缺少 Sample / Batch 列。")
  b <- trimws(as.character(df$Batch))
  if (any(is.na(b) | b == "")) return("存在空批次名。")
  tb <- table(b)
  if (length(tb) < 2) return("至少需要 2 个批次（全部样本同属一批时无需去批次）。")
  if (any(tb < 2))
    return(sprintf("每个批次至少需要 2 个样本；当前 %s 批仅 1 个样本。",
                   paste(names(tb)[tb < 2], collapse = ", ")))
  if (!is.null(snames)) {
    miss <- setdiff(snames, as.character(df$Sample))
    if (length(miss) > 0)
      return(paste0("批次表未覆盖以下样本：", paste(miss, collapse = ", ")))
  }
  NULL
}

# ---- 组名推断: 先去尾部序号, 再取末段; 需 >=2 组且每组 >=2 样本 ----
infer_groups <- function(snames) {
  if (is.null(snames) || length(snames) == 0) return(NULL)
  rules <- list(
    function(x) sub("[-_. ]?[0-9]+$", "", x),   # 去尾部序号
    function(x) sub("^.*[-_. ]", "", x))       # 取最后一个分隔符之后
  for (f in rules) {
    g <- f(snames)
    ok <- !any(is.na(g) | trimws(g) == "") &&
          length(unique(g)) >= 2 &&
          length(unique(g)) < length(snames) &&
          all(as.integer(table(g)) >= 2)
    if (ok) return(g)
  }
  NULL
}

# ---- 解析样本列 -> 显示名与分组 ----
resolve_groups <- function(sample_cols, sample_map, sample_rename = NULL) {
  snames <- make.unique(sub("\\.[^.]+$", "", basename(sample_cols)), sep = "_")
  # 用户自定义样本名: names = 原始样本列名, 值 = 新名 (在分组匹配前替换)
  if (!is.null(sample_rename) && length(sample_rename) > 0) {
    hit <- match(sample_cols, names(sample_rename))
    snames[!is.na(hit)] <- as.character(sample_rename[hit[!is.na(hit)]])
    snames <- make.unique(snames, sep = "_")
  }
  map <- normalize_sample_map(sample_map)
  if (is.null(map)) {
    infer <- infer_groups(snames)
    if (is.null(infer)) {
      stop("无法从样本列名自动推断分组 (已尝试\"尾部序号\"与\"末段后缀\"两种命名约定, ",
           "仍得不到 >=2 组且每组 >=2 样本)。\n",
           "  样本列: ", paste(sample_cols, collapse = ", "), "\n",
           "  请在「分组设置」中显式指定 样本->组 映射")
    }
    groups  <- infer
    map_src <- "auto"
  } else {
    match_col <- function(s) {
      if (s %in% sample_cols) return(s)
      hit <- sample_cols[snames == s]
      if (length(hit) == 1) return(hit)
      NA_character_
    }
    grp_by_col <- stats::setNames(map$Group, vapply(map$Sample, match_col, character(1)))
    miss <- is.na(names(grp_by_col))
    if (any(miss))
      stop("分组表中的以下样本未在数据列中找到: ",
           paste(map$Sample[miss], collapse = ", "))
    miss2 <- setdiff(sample_cols, names(grp_by_col))
    if (length(miss2) > 0)
      stop("数据中以下样本列未被分组表覆盖: ", paste(miss2, collapse = ", "))
    groups  <- unname(grp_by_col[sample_cols])
    map_src <- "explicit"
  }
  group_levels <- unique(groups)
  list(snames = snames, groups = groups, group_levels = group_levels,
       n_groups = length(group_levels), map_src = map_src)
}

# ---- 物种检测 (UniProt 后缀 _HUMAN/_MOUSE/_RAT, 或 Organism 列) ----
detect_species <- function(annot) {
  desc_text <- paste(c(annot$Protein.Names, annot$First.Protein.Description), collapse = " ")
  org_text  <- paste(annot$Organism, collapse = " ")
  hit <- function(pat) grepl(pat, desc_text) ||
                       grepl(pat, org_text, ignore.case = TRUE)
  if (hit("_HUMAN|HUMAN|Homo sapiens")) {
    list(species = "Homo sapiens", org_pkg = "org.Hs.eg.db", kegg_org = "hsa")
  } else if (hit("_MOUSE|MOUSE|Mus musculus")) {
    list(species = "Mus musculus", org_pkg = "org.Mm.eg.db", kegg_org = "mmu")
  } else if (hit("_RAT|RAT|Rattus norvegicus")) {
    list(species = "Rattus norvegicus", org_pkg = "org.Rn.eg.db", kegg_org = "rno")
  } else if (hit("_DANRE|DANRE|Danio rerio")) {
    list(species = "Danio rerio", org_pkg = "org.Dr.eg.db", kegg_org = "dre")
  } else {
    list(species = "Homo sapiens (default)", org_pkg = "org.Hs.eg.db", kegg_org = "hsa",
         warn = "未检测到明确物种标识，默认按 Human (org.Hs.eg.db) 注释")
  }
}

# ---- 输入读取 (tsv/csv/txt, 按首行分隔符判定) ----
read_input_file <- function(path) {
  first <- tryCatch(readLines(path, n = 1, warn = FALSE),
                    error = function(e) readLines(path, n = 1, warn = FALSE, encoding = "latin1"))
  sep <- if (any(grepl("\t", first, fixed = TRUE))) "\t"
         else if (any(grepl(",", first, fixed = TRUE))) ","
         else "\t"
  tryCatch(
    utils::read.delim(path, check.names = FALSE, sep = sep,
                      na.strings = c("NA", "", "NaN"), fileEncoding = "UTF-8"),
    error = function(e)
      utils::read.delim(path, check.names = FALSE, sep = sep, na.strings = c("NA", "", "NaN")))
}

# ---- 插补: mnar (LoD) 左截断高斯 / mar kNN(k=10) / seq 顺序 KNN ----

# LoD 左截断高斯 (逐样本列)
impute_mnar_gaussian <- function(mat, shift = 1.8, sd_scale = 0.3, seed = 42) {
  out <- as.data.frame(as.matrix(mat), check.names = FALSE)
  set.seed(seed)
  for (j in seq_len(ncol(out))) {
    idx_na <- is.na(out[, j])
    if (!any(idx_na)) next
    mu <- mean(out[!idx_na, j], na.rm = TRUE)
    sd <- stats::sd(out[!idx_na, j], na.rm = TRUE)
    if (is.na(sd) || sd == 0) sd <- 0.5
    out[idx_na, j] <- stats::rnorm(sum(idx_na), mean = mu - shift * sd,
                                   sd = sd_scale * sd)
  }
  out
}

# kNN; 不可用时退回该蛋白的行中位数
impute_mar_knn <- function(mat, k = 10) {
  m <- as.matrix(mat)
  if (!anyNA(m)) return(as.data.frame(m, check.names = FALSE))
  fallback <- function(mm) {
    rm <- apply(mm, 1, stats::median, na.rm = TRUE)
    if (all(!is.finite(rm))) rm <- rep(mean(mm, na.rm = TRUE), nrow(mm))
    if (any(!is.finite(rm))) rm[!is.finite(rm)] <- mean(rm[is.finite(rm)])
    for (j in seq_len(ncol(mm))) {
      idx <- is.na(mm[, j]); if (any(idx)) mm[idx, j] <- rm[idx]
    }
    mm
  }
  usable <- nrow(m) >= 2 && ncol(m) >= 2 &&
            !any(rowSums(!is.na(m)) == 0) && !any(colSums(!is.na(m)) == 0) &&
            requireNamespace("impute", quietly = TRUE)
  if (usable) {
    res <- tryCatch({
      tmp <- NULL
      # 吞掉 impute.knn 的控制台输出
      utils::capture.output(tmp <- impute::impute.knn(m, k = min(k, nrow(m) - 1L),
                                                      rowmax = 1, colmax = 1)$data)
      tmp
    }, error = function(e) NULL)
    if (!is.null(res) && !anyNA(res)) return(as.data.frame(res, check.names = FALSE))
  }
  as.data.frame(fallback(m), check.names = FALSE)
}

# 顺序 KNN (SeqKNN): 按缺失率从低到高逐蛋白插补, 已插补的蛋白参与后续距离计算
impute_seqknn <- function(mat, k = 10) {
  m <- as.matrix(mat)
  if (!anyNA(m)) return(m)
  miss <- rowMeans(is.na(m))
  miss[is.nan(miss)] <- 1
  done <- miss == 0
  gmed <- stats::median(m, na.rm = TRUE)
  if (!is.finite(gmed)) gmed <- 0
  for (i in order(miss)) {
    if (done[i]) next
    obs  <- which(!is.na(m[i, ]))
    gaps <- which(is.na(m[i, ]))
    if (length(obs) < 2) { m[i, gaps] <- gmed; done[i] <- TRUE; next }
    ref <- which(done & rowSums(is.na(m[, obs, drop = FALSE])) == 0)
    if (length(ref) < 1) { m[i, gaps] <- stats::median(m[i, obs]); done[i] <- TRUE; next }
    Rref <- m[ref, obs, drop = FALSE]
    for (s in gaps) {
      # d 的长度 = 观测样本数, 邻居只能取自这些样本
      d <- sqrt(colSums((Rref - m[ref, s])^2, na.rm = TRUE))
      d[!is.finite(d)] <- Inf
      kk <- min(k, sum(is.finite(d)))
      if (kk < 1) { m[i, s] <- stats::median(m[i, obs]); next }
      ord <- order(d)[seq_len(kk)]
      nn  <- obs[ord]                           # 邻居的真实样本号
      w   <- 1 / pmax(d[ord], 1e-8)
      m[i, s] <- sum(w * m[i, nn]) / sum(w)
    }
    done[i] <- TRUE
  }
  m
}

# 插补入口: 返回 list(mat, method); none 时原样返回 (保留 NA)
impute_missing <- function(mat, method = "mnar", shift = 1.8, sd_scale = 0.3, seed = 42) {
  if (is.null(method) || length(method) != 1L || is.na(method)) method <- "mnar"
  method <- as.character(method)
  # 未知 / 历史取值 (如已移除的 hybrid) 一律回退到 LoD
  if (!method %in% c("none", "mnar", "mar", "seq")) method <- "mnar"
  if (identical(method, "none"))
    return(list(mat = mat, method = "none"))
  if (!anyNA(mat))
    return(list(mat = mat, method = method))
  switch(method,
         mnar = list(mat = impute_mnar_gaussian(mat, shift, sd_scale, seed), method = "mnar"),
         mar  = list(mat = impute_mar_knn(mat), method = "mar"),
         seq  = list(mat = impute_seqknn(mat), method = "seq"))
}

# ---- ComBat 去批次: 分组作协变量; 需完整矩阵 (插补后), 否则跳过 ----
combat_correct <- function(mat, batch, groups = NULL, par_prior = TRUE) {
  if (!requireNamespace("sva", quietly = TRUE))
    return(list(ok = FALSE, mat = mat, note = NA_character_,
                reason = "未安装 sva 包 (Bioconductor), 无法执行 ComBat"))
  m <- as.matrix(mat)
  if (anyNA(m))
    return(list(ok = FALSE, mat = mat, note = NA_character_,
                reason = "矩阵含缺失值, ComBat 需要完整矩阵 (请先选择一种插补方法)"))
  b <- factor(as.character(batch), levels = unique(as.character(batch)))
  if (nlevels(b) < 2)
    return(list(ok = FALSE, mat = mat, note = NA_character_, reason = "批次数 < 2"))
  # 完全混杂 (每批只含一组) 会抹掉组间差异, 直接拒绝
  if (!is.null(groups)) {
    g_by_b <- split(as.character(groups), as.character(batch))
    if (all(vapply(g_by_b, function(g) length(unique(g)) == 1L, logical(1))))
      return(list(ok = FALSE, mat = mat, note = NA_character_,
                  reason = "批次与分组完全混杂（每个批次只含一个分组），去批次会连组间差异一起抹掉"))
  }
  mod <- if (is.null(groups)) NULL else stats::model.matrix(~ factor(groups))

  # 静音 ComBat 的过程输出
  run <- function(pp) {
    res <- NULL
    ok <- tryCatch({
      withCallingHandlers(
        utils::capture.output(res <- sva::ComBat(dat = m, batch = b, mod = mod,
                                                 par.prior = pp)),
        warning = function(w) invokeRestart("muffleWarning"),
        message = function(msg) invokeRestart("muffleMessage"))
      TRUE
    }, error = function(e) NULL)
    if (isTRUE(ok) && is.matrix(res) && !anyNA(res)) res else NULL
  }
  res <- run(TRUE); note <- "参数经验贝叶斯"
  if (is.null(res)) { res <- run(FALSE); note <- "非参数经验贝叶斯" }
  if (is.null(res))
    return(list(ok = FALSE, mat = mat, note = NA_character_,
                reason = "ComBat 计算失败（批次与分组可能完全混杂, 或存在零方差蛋白）"))
  if (!identical(dim(res), dim(m)))
    return(list(ok = FALSE, mat = mat, note = NA_character_,
                reason = "ComBat 返回矩阵维度异常, 已放弃校正"))
  dimnames(res) <- dimnames(m)          # ComBat 保持行序/列序, 这里再对齐一次
  list(ok = TRUE, mat = as.data.frame(res, check.names = FALSE), note = note,
       reason = NA_character_)
}

# ---- 主流程 ----
prep_run <- function(raw, params = list(), sample_group_map = NULL, annot_cols = NULL,
                     seed = 42, impute_shift = 1.8, impute_sd_scale = 0.3,
                     sample_batch_map = NULL, sample_rename = NULL) {
  warnings <- character(0)
  add_warning <- function(msg) warnings <<- c(warnings, msg)

  min_detect_frac <- params$min_detect_frac %||% 0.5

  stopifnot(is.data.frame(raw), nrow(raw) > 0, ncol(raw) > 1)
  n_before <- nrow(raw)

  # ---- 注释列识别 ----
  if (is.null(annot_cols)) {
    annot_map <- auto_annot_cols(colnames(raw), params$source %||% "diann")
  } else {
    if (is.null(names(annot_cols)) || any(names(annot_cols) == ""))
      stop("显式 annot_cols 必须是命名字符向量, 形如 c(Protein.Group=\"Protein.Group\", Genes=\"PG.Genes\")")
    annot_map <- as.list(annot_cols)
  }
  take_col <- function(nm) {
    hit <- annot_map[[nm]]
    if (is.null(hit) || is.na(hit)) return(rep(NA_character_, nrow(raw)))
    as.character(raw[[hit]])
  }
  annot <- data.frame(
    Protein.Group             = take_col("Protein.Group"),
    Protein.Names             = take_col("Protein.Names"),
    Genes                     = take_col("Genes"),
    First.Protein.Description = take_col("First.Protein.Description"),
    Organism                  = take_col("Organism"),   # Spectronaut PG.Organisms, DIA-NN 为 NA
    N.Sequences               = take_col("N.Sequences"),
    N.Proteotypic.Sequences   = take_col("N.Proteotypic.Sequences"),
    stringsAsFactors = FALSE)
  if (all(is.na(annot$Protein.Group)))
    stop("未能识别蛋白 ID 注释列。请检查输入列名, 或在「高级设置」中指定 ID 列。")
  if (all(is.na(annot$Genes)))
    add_warning("未识别到 Genes 注释列, 基因注释相关输出(火山图标注/富集)将受限")

  # ---- 样本列 = 全部非注释列 ----
  annot_used <- unlist(annot_map[!is.na(unlist(annot_map))])
  sample_cols <- setdiff(colnames(raw), annot_used)
  if (length(sample_cols) < 2) stop("未识别到样本定量列，请检查输入格式")
  # 判据: 只看"有值却无法转数值"的比例, NA 不计入
  num_ratio <- vapply(sample_cols, function(s) {
    v <- raw[[s]]
    mean(!is.na(v) & is.na(suppressWarnings(as.numeric(v))))
  }, numeric(1))
  if (any(num_ratio > 0.5))
    stop("以下列既不是注释列也非数值样本列, 请检查输入:\n  ",
         paste(sample_cols[num_ratio > 0.5], collapse = ", "))

  # ---- 样本/分组解析 ----
  parsed <- resolve_groups(sample_cols, sample_group_map, sample_rename = sample_rename)
  snames       <- parsed$snames
  groups       <- parsed$groups
  group_levels <- parsed$group_levels
  n_groups     <- parsed$n_groups
  if (n_groups < 2) stop("需要至少两个分组才能进行差异分析")
  names(sample_cols) <- snames

  # ---- 对照组 (默认第一组) ----
  control_grp <- params$control_grp %||% group_levels[1]
  if (!control_grp %in% group_levels) control_grp <- group_levels[1]

  # ---- 表达矩阵 (数值化) ----
  expr_raw <- as.data.frame(lapply(raw[, sample_cols, drop = FALSE],
                                   function(x) suppressWarnings(as.numeric(x))))
  rownames(expr_raw) <- annot$Protein.Group
  colnames(expr_raw) <- snames
  expr_raw[expr_raw <= 0] <- NA   # 0/负值视为缺失 (DIA-NN 习惯)

  # ---- 过滤: 污染/反库 + 低检出 ----
  is_contaminant <- grepl("contaminant", annot$Protein.Group, ignore.case = TRUE) |
                    grepl("REV_|DECOY_|^REV|^DECOY", annot$Protein.Group) |
                    grepl("contaminant|Reverse|Decoy", annot$First.Protein.Description,
                          ignore.case = TRUE)
  n_contam <- sum(is_contaminant)
  if (n_contam > 0)
    add_warning(sprintf("过滤了 %d 条污染/反库(REV/DECOY)条目", n_contam))

  keep <- !is_contaminant
  expr_raw <- expr_raw[keep, , drop = FALSE]
  annot    <- annot[keep, , drop = FALSE]

  detect_frac <- rowSums(!is.na(expr_raw)) / ncol(expr_raw)
  keep2 <- detect_frac >= min_detect_frac
  n_low <- sum(!keep2)
  expr_raw <- expr_raw[keep2, , drop = FALSE]
  annot    <- annot[keep2, , drop = FALSE]
  detect_frac <- detect_frac[keep2]
  n_final <- nrow(expr_raw)
  add_warning(sprintf("低检出过滤 (>=%.0f%%检出) 剔除 %d 个蛋白", min_detect_frac * 100, n_low))
  if (n_final == 0) stop("过滤后无剩余蛋白，请降低低检出过滤阈值 (min_detect_frac)")

  # ---- 过滤: 分组内最少检测样本数 (0 = 不启用; 任一分组达到阈值即保留) ----
  min_group_detect <- suppressWarnings(as.numeric(params$min_group_detect %||% 0)[1])
  if (is.na(min_group_detect) || !is.finite(min_group_detect) || min_group_detect < 0)
    min_group_detect <- 0
  n_group_low <- 0L
  if (min_group_detect > 0) {
    det_by_group <- matrix(
      vapply(group_levels, function(g) {
        idx <- which(groups == g)
        if (length(idx) == 0) return(rep(0, nrow(expr_raw)))
        as.numeric(rowSums(!is.na(expr_raw[, idx, drop = FALSE])))
      }, numeric(nrow(expr_raw))),
      nrow = nrow(expr_raw))
    keep_g <- rowSums(det_by_group >= min_group_detect) >= 1
    n_group_low <- sum(!keep_g)
    expr_raw    <- expr_raw[keep_g, , drop = FALSE]
    annot       <- annot[keep_g, , drop = FALSE]
    detect_frac <- detect_frac[keep_g]
    add_warning(sprintf("分组内最少检测样本数过滤 (任一分组 >= %d 个样本检出) 剔除 %d 个蛋白",
                        min_group_detect, n_group_low))
    if (nrow(expr_raw) == 0)
      stop("分组内最少检测样本数过滤后无剩余蛋白，请降低该阈值")
    n_final <- nrow(expr_raw)
  }

  # ---- 缺失值评估 ----
  miss_per_sample <- colMeans(is.na(expr_raw))
  miss_per_prot   <- rowMeans(is.na(expr_raw))
  miss_df <- data.frame(Sample = snames, Group = groups,
                        MissingRate = round(miss_per_sample * 100, 2))

  # ---- log2 变换 (归一化在插补之后) ----
  expr_log2 <- log2(expr_raw)
  expr_log2[is.na(expr_raw)] <- NA
  expr_norm <- expr_log2     # 插补前 (含 NA)

  # ---- 缺失值插补 ----
  impute_res    <- impute_missing(expr_norm, params$impute_method %||% "mnar",
                                  impute_shift, impute_sd_scale, seed)
  expr_imp_raw  <- impute_res$mat            # 插补后、归一化前
  impute_method <- impute_res$method
  imputed       <- !identical(impute_method, "none")
  n_missing     <- sum(is.na(expr_norm))
  n_imp         <- if (imputed) n_missing else 0L

  # ---- 样本中位数归一化: 平移到最大值, 只做加法 ----
  medians       <- apply(as.matrix(expr_imp_raw), 2, stats::median, na.rm = TRUE)
  median_target <- suppressWarnings(max(medians, na.rm = TRUE))
  if (!is.finite(median_target)) median_target <- 0
  median_shift  <- median_target - medians
  median_shift[!is.finite(median_shift)] <- 0
  expr_imp      <- sweep(as.matrix(expr_imp_raw), 2, median_shift, "+")
  # 线性尺度 (= 2^expr_imp), 不参与下游
  expr_imp_lin  <- 2 ^ expr_imp

  if (identical(impute_method, "none")) {
    add_warning(sprintf("缺失值处理方式：不填补（保留 %d 个缺失值，占 %.2f%%）；已停用差异分析与功能富集",
                        n_missing, n_missing / (nrow(expr_imp) * ncol(expr_imp)) * 100))
  } else if (identical(impute_method, "mar")) {
    add_warning("缺失值插补：随机缺失型（k 近邻, k=10）")
  }
  add_warning(sprintf("样本中位数归一化：各样本中位数对齐到最大值 %.2f（平移 %.2f ~ %.2f）",
                      median_target, min(median_shift), max(median_shift)))

  # ---- 去批次 (可选) ----
  use_combat    <- isTRUE(params$use_combat)
  expr_prebatch <- expr_imp
  combat_done   <- FALSE
  combat_note   <- NA_character_
  combat_reason <- NA_character_
  batch_vec     <- NULL
  n_batches     <- 0L
  if (use_combat) {
    bm  <- tryCatch(normalize_batch_map(sample_batch_map), error = function(e) NULL)
    err <- if (is.null(bm)) "未提供批次表" else validate_batch_map(bm, snames)
    if (!is.null(err)) {
      combat_reason <- paste0(err, "（请在「① 数据与分组」的批次设置中填写并应用）")
      add_warning(paste0("去批次未执行：", combat_reason))
    } else {
      batch_vec <- unname(stats::setNames(as.character(bm$Batch), as.character(bm$Sample))[snames])
      n_batches <- length(unique(batch_vec))
      res <- combat_correct(expr_imp, batch_vec, groups)
      if (isTRUE(res$ok)) {
        expr_imp      <- res$mat
        combat_done   <- TRUE
        combat_note   <- res$note
        add_warning(sprintf("去批次校正：ComBat（%s），%d 个批次（%s），分组作为协变量保留",
                            combat_note, n_batches, paste(unique(batch_vec), collapse = " / ")))
      } else {
        combat_reason <- res$reason
        add_warning(paste0("去批次未执行：", combat_reason))
      }
    }
  }

  # ---- 检出数 ----
  det_sample <- colSums(!is.na(expr_raw))
  det_prot   <- rowSums(!is.na(expr_raw))

  # ---- 物种 ----
  sp <- if (!is.null(params$species) && !identical(params$species, "auto")) {
    switch(as.character(params$species),
           human     = list(species = "Homo sapiens",       org_pkg = "org.Hs.eg.db", kegg_org = "hsa"),
           mouse     = list(species = "Mus musculus",       org_pkg = "org.Mm.eg.db", kegg_org = "mmu"),
           rat       = list(species = "Rattus norvegicus",  org_pkg = "org.Rn.eg.db", kegg_org = "rno"),
           zebrafish = list(species = "Danio rerio",        org_pkg = "org.Dr.eg.db", kegg_org = "dre"),
           detect_species(annot))
  } else detect_species(annot)
  if (!is.null(sp$warn)) add_warning(sp$warn)

  grp_col <- get_group_colors(n_groups)
  names(grp_col) <- group_levels

  list(
    # 数据
    raw          = raw,
    annot        = annot,
    annot_map    = annot_map,
    sample_cols  = sample_cols,
    snames       = snames,
    groups       = groups,
    group_levels = group_levels,
    n_groups     = n_groups,
    map_src      = parsed$map_src,
    control_grp  = control_grp,
    expr_raw     = expr_raw,
    expr_log2    = expr_log2,
    expr_imp_raw = expr_imp_raw,
    expr_imp_lin = expr_imp_lin,
    expr_norm    = expr_norm,
    expr_prebatch = expr_prebatch,
    expr_imp     = expr_imp,
    # 统计
    n_before = n_before, n_contam = n_contam, n_low = n_low,
    n_group_low = n_group_low, n_final = n_final,
    n_imp = n_imp, n_missing = n_missing, imputed = imputed,
    imp_pct = n_imp / (nrow(expr_imp) * ncol(expr_imp)) * 100,
    miss_pct = n_missing / (nrow(expr_imp) * ncol(expr_imp)) * 100,
    miss_per_sample = miss_per_sample, miss_per_prot = miss_per_prot, miss_df = miss_df,
    detect_frac = detect_frac, det_sample = det_sample, det_prot = det_prot,
    medians = medians, median_target = median_target, median_shift = median_shift,
    # 参数
    min_detect_frac = min_detect_frac, min_group_detect = min_group_detect,
    impute_method = impute_method,
    impute_shift = impute_shift, impute_sd_scale = impute_sd_scale, seed = seed,
    # 去批次 (ComBat)
    use_combat = use_combat, combat_done = combat_done, combat_note = combat_note,
    combat_reason = combat_reason, batch_vec = batch_vec, n_batches = n_batches,
    # 物种与配色
    species = sp$species, org_pkg = sp$org_pkg, kegg_org = sp$kegg_org,
    grp_col = grp_col,
    # 告警
    warnings = warnings
  )
}
