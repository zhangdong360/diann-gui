# v1.15 i18n 契约测试
# 1) 覆盖完整性: R/ 全部 tr_("字面 key") 必须在 inst/i18n/translations.json
#    中有非空 en 译文 (防止"加了 tr_ 忘补翻译"静默回退中文);
# 2) 占位符一致: zh/en 的 %s/%d 数量与顺序一致 (sprintf 展开才不会错位);
# 3) 行为: 回退/显式语言/覆盖栈/持久化写回/doctor(lang=)/app_ui 随语言渲染。
# 注: 其余测试经 helper.R 钉 DIANN_GUI_LANG=zh; 本文件单独验证 en 行为,
#     每个用例自管语言环境并在退出时还原。

nsget <- function(n) get(n, envir = asNamespace("diann.gui"))
tr_ <- nsget("tr_"); i18n_match_lang <- nsget("i18n_match_lang")
i18n_lang <- nsget("i18n_lang"); i18n_push_lang <- nsget("i18n_push_lang")
i18n_pop_lang <- nsget("i18n_pop_lang"); i18n_reset <- nsget("i18n_reset")
i18n_table <- nsget("i18n_table"); user_config_write_lang <- nsget("user_config_write_lang")
resolve_user_config <- nsget("resolve_user_config")

with_lang <- function(lang, code) {
  old <- Sys.getenv("DIANN_GUI_LANG", unset = "")
  Sys.setenv(DIANN_GUI_LANG = lang)
  on.exit({
    if (nzchar(old)) Sys.setenv(DIANN_GUI_LANG = old) else Sys.unsetenv("DIANN_GUI_LANG")
    i18n_reset()
  }, add = TRUE)
  i18n_reset()
  force(code)
}

# ---------- 1) 翻译表静态契约 ----------

i18n_tab <- function() {
  f <- system.file("i18n", "translations.json", package = "diann.gui")
  skip_if_not(nzchar(f) && file.exists(f), "translations.json 未安装")
  x <- jsonlite::fromJSON(f)
  stopifnot(identical(as.character(x$languages), c("zh", "en")))
  t <- x$translation
  stopifnot(is.data.frame(t), all(c("zh", "en") %in% names(t)))
  t
}

test_that("翻译表: 无重复 key, en 全部非空", {
  t <- i18n_tab()
  expect_false(any(duplicated(t$zh)))
  expect_true(all(nzchar(trimws(t$en))))
})

# AST 提取 R/ 源码里全部 tr_ 的字面 key (与 helper.R 的源码树探测同约定)
i18n_source_keys <- function() {
  root <- PROJECT_ROOT
  skip_if_not(nzchar(root), "安装态测试无源码树, 跳过静态扫描")
  keys <- character(0)
  for (f in list.files(file.path(root, "R"), pattern = "\\.R$", full.names = TRUE)) {
    p <- parse(f)
    walk <- function(x) {
      if (is.call(x)) {
        if (identical(deparse(x[[1]]), "tr_") && length(x) >= 2 &&
            is.character(x[[2]]) && length(x[[2]]) == 1L && nzchar(x[[2]])) {
          keys[[length(keys) + 1L]] <<- x[[2]]
        }
        for (i in seq_along(x)) if (is.call(x[[i]]) || is.language(x[[i]])) walk(x[[i]])
      }
    }
    for (e in p) walk(e)
  }
  unique(keys)
}

test_that("覆盖完整性: R/ 全部 tr_ key 都有英文译文", {
  t <- i18n_tab()
  keys <- i18n_source_keys()
  skip_if_not(length(keys) > 0, "未扫到 tr_ key")
  miss <- setdiff(keys, t$zh)
  expect_length(miss, 0)
  empty <- keys[keys %in% t$zh & !nzchar(trimws(t$en[match(keys, t$zh)]))]
  expect_length(empty, 0)
})

test_that("占位符一致: zh/en 的 sprintf 占位符数量与顺序相同", {
  t <- i18n_tab()
  ph <- function(s) regmatches(s, gregexpr("%[0-9.]*[sd]", s, perl = TRUE))[[1]]
  bad <- vapply(seq_len(nrow(t)), function(i) {
    !identical(ph(t$zh[i]), ph(t$en[i]))
  }, logical(1))
  if (any(bad)) {
    msg <- paste(utils::head(sprintf("%s || %s", t$zh[bad], t$en[bad]), 5), collapse = "; ")
    fail(sprintf("%d 条 zh/en 占位符不一致: %s", sum(bad), msg))
  }
  succeed("占位符全部一致")
})

# ---------- 2) 运行行为 ----------

test_that("tr_: zh 原样 / en 查表 / 未命中回退 / sprintf 展开", {
  with_lang("zh", {
    expect_equal(tr_("界面语言"), "界面语言")
    expect_equal(tr_("已达上限 %d (%s)", 4L, "x"), "已达上限 4 (x)")
  })
  with_lang("en", {
    expect_equal(tr_("界面语言"), "UI language")
    # 翻译表未收录的 key 回退中文原文 (覆盖完整性由静态测试保证)
    expect_equal(tr_("绝不存在的键__"), "绝不存在的键__")
    expect_equal(tr_("已达上限 %d (%s)", 4L, "x"), "已达上限 4 (x)")
  })
  # .lang 显式覆盖一切
  expect_equal(tr_("界面语言", .lang = "en"), "UI language")
  expect_equal(tr_("界面语言", .lang = "ZH"), "界面语言")
  expect_equal(tr_("界面语言", .lang = "fr"), "UI language")  # 未知值按 en
})

test_that("i18n_match_lang / 环境变量优先级", {
  expect_equal(i18n_match_lang("zh"), "zh")
  expect_equal(i18n_match_lang("ZH-CN"), "zh")
  expect_equal(i18n_match_lang("en"), "en")
  expect_equal(i18n_match_lang("fr"), "en")
  expect_equal(i18n_match_lang(NULL), "en")
  # 配置 zh > 默认 en
  set_core_const("LANG", "zh")
  on.exit(set_core_const("LANG", NULL), add = TRUE)
  with_lang("", expect_equal(i18n_lang(), "zh"))
  with_lang("en", expect_equal(i18n_lang(), "en"))  # 环境变量 > 配置
})

test_that("语言覆盖栈: doctor(lang=) 式 push/pop 不影响外部", {
  with_lang("en", {
    i18n_push_lang("zh")
    expect_equal(i18n_lang(), "zh")
    i18n_pop_lang()
    expect_equal(i18n_lang(), "en")
  })
})

test_that("user_config_write_lang: 写回/就地替换/内存同步", {
  with_lang("en", {
    before <- resolve_user_config()
    f <- user_config_write_lang("zh")
    on.exit(if (nzchar(before) && before != f && file.exists(before)) NULL else NULL, add = TRUE)
    expect_true(file.exists(f))
    lines <- readLines(f, warn = FALSE)
    expect_true(any(grepl('^LANG <- "zh"$', lines)))
    # 再切回: 就地替换而不是追加
    f2 <- user_config_write_lang("en")
    expect_identical(f2, f)
    lines2 <- readLines(f, warn = FALSE)
    expect_equal(sum(grepl("^LANG <- ", lines2)), 1L)
    expect_true(any(grepl('^LANG <- "en"$', lines2)))
    expect_equal(i18n_lang(), "en")
  })
})

test_that("doctor(lang=): en/zh 输出随语言切换", {
  d_en <- suppressWarnings(doctor(lang = "en", backend = "slurm",
                                  slurm_cmds = c(sbatch = "/x/sbatch", squeue = "/x/squeue",
                                                 sacct = "/x/sacct", sinfo = "/x/sinfo",
                                                 scontrol = "/x/scontrol")))
  d_zh <- suppressWarnings(doctor(lang = "zh", backend = "slurm",
                                  slurm_cmds = c(sbatch = "/x/sbatch", squeue = "/x/squeue",
                                                 sacct = "/x/sacct", sinfo = "/x/sinfo",
                                                 scontrol = "/x/scontrol")))
  expect_false(is.null(d_en))
  expect_equal(unique(d_en$group)[1], "Execution backend")
  expect_equal(unique(d_zh$group)[1], "执行后端")
  expect_false(identical(d_en$group, d_zh$group))
  # 组顺序与重要性契约不受语言影响 (test-doctor.R 断言 zh 顺序)
  expect_equal(unique(d_en$group)[length(unique(d_en$group))], "Slurm dependencies")
})

test_that("app_ui 随语言渲染 (写配置 + 刷新生效的前提)", {
  ui_en <- with_lang("en", as.character(nsget("app_ui")()))
  ui_zh <- with_lang("zh", as.character(nsget("app_ui")()))
  expect_false(identical(ui_en, ui_zh))
  expect_true(any(grepl("lang_switch", ui_en)))
  expect_true(any(grepl("diann_gui_reload", ui_en)))
})
