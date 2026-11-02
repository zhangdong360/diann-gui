# ============================================================
# i18n.R — UI 文案中英文切换 (v1.15)
#
# 基于 shiny.i18n::Translator 加载翻译表 inst/i18n/translations.json
# (key = 中文原文, languages 首列 "zh" 即 key 语言, "en" 列为英文译文;
#  与 shiny.i18n 的 CSV/JSON 约定一致, 未来可无缝切到 automatic_translate)。
#
# 语言解析顺序: i18n_push_lang 显式栈 (doctor(lang=) 等局部覆盖)
#   > 环境变量 DIANN_GUI_LANG (部署/测试钉死)
#   > 配置键 LANG (UI 语言切换写回 ~/.diann_gui/config.R)
#   > 默认 "en"。
#
# tr_() 无状态查表: zh 模式原样返回中文原文; en 模式查 en 列, 未命中回退
# 中文原文 (覆盖完整性由 test-i18n.R 静态扫描保证, 运行期不 warning)。
# 语言切换 = 写配置 + 页面刷新 (app_ui/server 在会话启动时读取一次)。
# ============================================================

.i18n <- new.env(parent = emptyenv())
.i18n$table <- NULL
.i18n$lang_stack <- character(0)

I18N_LANGS <- c("en", "zh")

# 语言值规范化: 仅认 "zh", 其余一律 "en" (默认英文)
i18n_match_lang <- function(x) {
  x <- tolower(trimws(as.character(x %||% "")))
  if (length(x) == 1L && nzchar(x) && x %in% c("zh", "zh_cn", "zh-cn", "chinese")) "zh" else "en"
}

# 当前生效语言 (每次 tr_ 调用时解析, 不缓存 — 会话期间配置只读不切换)
i18n_lang <- function() {
  n <- length(.i18n$lang_stack)
  if (n) return(.i18n$lang_stack[[n]])
  env <- trimws(tolower(Sys.getenv("DIANN_GUI_LANG", "")))
  if (nzchar(env)) return(i18n_match_lang(env))
  i18n_match_lang(cfg_get("LANG", default = "en"))
}

# 局部语言覆盖栈: doctor(lang=) 等入口在函数开头 push、on.exit pop
i18n_push_lang <- function(lang) {
  .i18n$lang_stack <- c(.i18n$lang_stack, i18n_match_lang(lang))
  invisible(NULL)
}
i18n_pop_lang <- function() {
  n <- length(.i18n$lang_stack)
  if (n) .i18n$lang_stack <- .i18n$lang_stack[-n]
  invisible(NULL)
}

# 翻译表 (data.frame: rownames=中文 key, 列 "en")。缓存; 缺文件/解析失败返回
# NULL — 此时 en 模式也回退中文原文, 包安装不完整不至于崩 UI。
i18n_table <- function() {
  if (!is.null(.i18n$table)) return(.i18n$table)
  f <- system.file("i18n", "translations.json", package = "diann.gui")
  tab <- NULL
  if (nzchar(f) && file.exists(f)) {
    tab <- tryCatch({
      tr <- shiny.i18n::Translator$new(translation_json_path = f)
      t <- tr$get_translations()
      if (is.data.frame(t) && "en" %in% names(t)) t[, "en", drop = FALSE] else NULL
    }, error = function(e) NULL)
  }
  .i18n$table <- tab
  tab
}

# 仅供测试: 清空缓存与语言栈
i18n_reset <- function() {
  .i18n$table <- NULL
  .i18n$lang_stack <- character(0)
  invisible(NULL)
}

# 翻译核心: key 为中文原文整句 (sprintf 模板含 %s/%d 时, 附加参数按位展开)。
# .lang 显式指定优先; 未命中/翻译表缺失回退 key 本身。
tr_ <- function(key, ..., .lang = NULL) {
  lang <- if (!is.null(.lang)) i18n_match_lang(.lang) else i18n_lang()
  txt <- key
  if (!identical(lang, "zh")) {
    tab <- i18n_table()
    if (!is.null(tab)) {
      v <- suppressWarnings(tab[key, "en"])
      if (length(v) == 1L && !is.na(v) && nzchar(v)) txt <- v
    }
  }
  if (...length()) txt <- tryCatch(sprintf(txt, ...), error = function(e) key)
  txt
}

# 语言切换持久化: 把 LANG 行写回用户配置文件 (已有 LANG 行就地替换, 否则追加)。
# 未解析到任何配置文件时新建最小 ~/.diann_gui/config.R; 同时更新内存 .cfg$LANG。
user_config_write_lang <- function(lang) {
  lang <- i18n_match_lang(lang)
  file <- resolve_user_config()
  if (!nzchar(file)) {
    file <- file.path(path.expand("~"), ".diann_gui", "config.R")
    dir.create(dirname(file), recursive = TRUE, showWarnings = FALSE, mode = "0700")
    if (!file.exists(file)) {
      writeLines(c("# diann.gui 每用户配置 (完整模板见 init_config() 生成的 config.example.R)",
                   sprintf('LANG <- "%s"', lang)),
                 file)
      Sys.chmod(file, "0600")
    }
  }
  txt <- paste(readLines(file, warn = FALSE), collapse = "\n")
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  line <- sprintf('LANG <- "%s"', lang)
  idx <- grep("^#?\\s*LANG\\s*<-", lines, perl = TRUE)
  if (length(idx)) lines[idx[1]] <- line else lines <- c(lines, line)
  writeLines(lines, file, useBytes = TRUE)
  try(Sys.chmod(file, "0600"), silent = TRUE)
  set_core_const("LANG", lang)
  invisible(file)
}

# 语言切换的 server 端观察者 (完整模式与 analysis_only 模式共用):
# 选了不同语言 → 写回用户配置 + 发 diann_gui_reload 消息 (ui.R 注册的 JS
# handler 收到后 location.reload(), 新会话按新语言重建 UI)。
lang_switch_server <- function(input, session) {
  observeEvent(input$lang_switch, {
    lang <- i18n_match_lang(input$lang_switch)
    if (identical(lang, i18n_lang())) return(invisible(NULL))
    try(user_config_write_lang(lang), silent = TRUE)
    session$sendCustomMessage("diann_gui_reload", list(lang = lang))
    invisible(NULL)
  })
}
