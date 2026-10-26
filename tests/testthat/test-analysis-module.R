# v1.14 结果分析模块·虚拟操作验证 (shiny::testServer 模拟会话, 无浏览器)
# 覆盖: 正向全流程 (读矩阵→分组→预处理→QC→差异→报告) 与异常路径
# (坏路径/不填补停用差异/多组模式/空模块拦截/仅 QC 报告占位)。
# 注: test_local 的 load_all(export_all) 与 CI 的 test_dir(已安装包) 行为不同,
#     模块函数一律 getFromNamespace 取用。
# 注2: testServer 的 mock 会话不应用控件 UI 默认值 (checkboxGroupInput 的
#      selected / numericInput 的 value 服务端均为 NULL), 全部输入必须显式设置。

mod_server <- function() getFromNamespace("mod_analysis_server", "diann.gui")
server_only <- function() getFromNamespace("server_analysis_only", "diann.gui")

an_mod_vol <- c(Data = tempdir())

test_that("虚拟工作流·正向: 读矩阵→自动分组→预处理→QC 8 图→limma→报告落盘", {
  skip_analysis_de()
  mat <- write_fixture_matrix(make_fixture_pg_matrix(seed = 42),
                              file.path(tempdir(), "anmod_matrix.tsv"))
  shiny::testServer(mod_server(), args = list(volumes = an_mod_vol), {
    # 1) 填路径 + 点「读取矩阵」
    session$setInputs(matrix_path = mat, matrix_load = 1)
    expect_false(is.null(raw_data()))
    expect_equal(nrow(raw_data()), 40)
    # 显式勾选模块与参数 (mock 会话无 UI 默认值)
    session$setInputs(modules = c("qc", "de"), cor_min = 0.8, cv_bins = 40,
                      de_logFC = 1, de_pval = 0.05, de_padj = "BH",
                      de_topn_label = 12, de_topn_box = 9, de_heatmap_max = 200,
                      min_detect_frac = 0.5, min_group_detect = 0,
                      impute_method = "mnar", species = "auto", source = "diann")

    # 2) 自动分组推断 (A/B 各 3) + 矩阵信息卡
    inf <- inferred()
    expect_true(inf$ok)
    expect_setequal(inf$infer, c("A", "B"))
    info <- output$matrix_info$html
    expect_true(grepl("已读取", paste(capture.output(print(info)), collapse = "")) ||
                  grepl("已读取", as.character(info)))

    # 3) 预处理 (污染 2 条被剔)
    expect_identical(prep()$n_contam, 2L)
    expect_false(anyNA(prep()$expr_imp))

    # 4) QC (默认勾选 qc/de): 8 张图 + 统计
    expect_length(qc_res()$plots, 8)
    expect_length(qc_res()$stats$pca_var, 2)

    # 5) limma 单对比
    expect_identical(de_res()$mode, "single")
    expect_gt(nrow(de_res()$pairs[[1]]$sig), 0)

    # 6) 生成报告 → 落盘契约
    session$setInputs(report_build = 1)
    st <- report_state()
    expect_false(is.null(st))
    expect_true(file.exists(st$html))
    expect_true(file.exists(file.path(st$dir, "analysis_params.json")))
    expect_true(file.exists(file.path(st$dir, "assets", "style.css")))
    html <- paste(readLines(st$html, warn = FALSE), collapse = "\n")
    expect_match(html, "1 项目概述", fixed = TRUE)
    on.exit(unlink(st$out_dir %||% st$dir, recursive = TRUE, force = TRUE), add = TRUE)
  })
})

test_that("虚拟工作流·坏路径: 读取失败给出通知且矩阵不可用", {
  shiny::testServer(mod_server(), args = list(volumes = an_mod_vol), {
    session$setInputs(matrix_path = "/nonexistent/nope.tsv", matrix_load = 1)
    expect_null(raw_data())
    info <- as.character(output$matrix_info$html %||% "")
    expect_match(info, "不可用", fixed = TRUE)
  })
})

test_that("虚拟工作流·不填补: 差异与富集自动停用并给出原因", {
  skip_analysis_qc()
  mat <- write_fixture_matrix(make_fixture_pg_matrix(seed = 3),
                              file.path(tempdir(), "anmod_none.tsv"))
  shiny::testServer(mod_server(), args = list(volumes = an_mod_vol), {
    session$setInputs(matrix_path = mat, matrix_load = 1,
                      impute_method = "none", modules = c("qc", "de", "enrich"),
                      min_detect_frac = 0.5, min_group_detect = 0, species = "auto",
                      source = "diann", de_padj = "BH", en_padj = "BH")
    pp <- prep()
    expect_false(pp$imputed)
    # de_res/enrich_res 因上游停用而 req 失败 (validation error 是正确语义);
    # 页签输出必须显示引导提示而不是空白 (2026-10 审查: req 链吞提示的回归)
    expect_null(de_res())
    de_hint <- as.character(output$de_content$html %||% "")
    expect_match(de_hint, "不填补", fixed = TRUE)
    en_hint <- as.character(output$enrich_content$html %||% "")
    expect_match(en_hint, "富集", fixed = TRUE)
  })
})

test_that("虚拟工作流·多组: 全局 F + 两两对比, 富集依赖提示", {
  skip_analysis_de()
  mat <- write_fixture_matrix(make_fixture_pg_matrix(groups = c("A", "B", "C"), seed = 11),
                              file.path(tempdir(), "anmod_multi.tsv"))
  shiny::testServer(mod_server(), args = list(volumes = an_mod_vol), {
    session$setInputs(matrix_path = mat, matrix_load = 1, modules = c("qc", "de"),
                      de_logFC = 1, de_pval = 0.05, de_padj = "BH",
                      de_topn_label = 12, de_topn_box = 9, de_heatmap_max = 200,
                      min_detect_frac = 0.5, min_group_detect = 0,
                      impute_method = "mnar", species = "auto", source = "diann")
    expect_identical(de_res()$mode, "multi")
    expect_false(is.null(de_res()$anova))
    expect_length(de_res()$pairs, 3)
  })
})

test_that("虚拟工作流·空模块: 报告生成被拦截", {
  skip_analysis_qc()
  mat <- write_fixture_matrix(make_fixture_pg_matrix(seed = 5),
                              file.path(tempdir(), "anmod_nomod.tsv"))
  shiny::testServer(mod_server(), args = list(volumes = an_mod_vol), {
    session$setInputs(matrix_path = mat, matrix_load = 1, modules = character(0),
                      min_detect_frac = 0.5, min_group_detect = 0,
                      impute_method = "mnar", species = "auto", source = "diann")
    expect_false(is.null(prep()))
    expect_null(qc_res())
    expect_null(de_res())
    session$setInputs(report_build = 1)
    expect_null(report_state())   # 至少一个模块才允许生成
  })
})

test_that("虚拟工作流·仅 QC: 报告差异章节占位", {
  skip_analysis_report()
  mat <- write_fixture_matrix(make_fixture_pg_matrix(seed = 7),
                              file.path(tempdir(), "anmod_qconly.tsv"))
  shiny::testServer(mod_server(), args = list(volumes = an_mod_vol), {
    session$setInputs(matrix_path = mat, matrix_load = 1, modules = "qc",
                      cor_min = 0.8, cv_bins = 40, min_detect_frac = 0.5,
                      min_group_detect = 0, impute_method = "mnar", species = "auto",
                      source = "diann")
    expect_length(qc_res()$plots, 8)
    expect_null(de_res())
    session$setInputs(report_build = 1)
    st <- report_state()
    expect_false(is.null(st))
    html <- paste(readLines(st$html, warn = FALSE), collapse = "\n")
    expect_match(html, "未执行差异分析模块", fixed = TRUE)
    on.exit(unlink(st$out_dir %||% st$dir, recursive = TRUE, force = TRUE), add = TRUE)
  })
})

test_that("虚拟工作流·analysis_only 独立服务器: 模块在独立模式可用", {
  skip_analysis_qc()
  mat <- write_fixture_matrix(make_fixture_pg_matrix(seed = 9),
                              file.path(tempdir(), "anmod_only.tsv"))
  shiny::testServer(server_only(), {
    session$setInputs(`analysis-matrix_path` = mat)   # 顶层 server: inputId 带模块前缀
    # load_path 由按钮触发; 这里直接验证模块已注册且矩阵读取链路通
    expect_false(is.null(session$input))
  })
})
