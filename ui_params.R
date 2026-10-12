# ============================================================
# ui_params.R — 「分析参数」UI: 控件 helper + 全局样式 + 六个参数子标签
# 环境契约: 由 app.R 在 library(shiny) 与 source(diann_core.R, local=TRUE)
# 之后以 local=TRUE source —— mod_row_ui 依赖 diann_core 的 vm_default,
# CSS 常量构造需要 shiny/htmltools。inputId 与 server 端 params_ready /
# reset_import_state 及 diann_core 的三个旗标映射一一对应, 改动必须三方
# 同步 (tests/testthat/test-consistency.R 守护)。
# ============================================================

mod_row_ui <- function(prefix, i, ncol1 = 4, value1 = "") {
  fluidRow(
    column(ncol1, textInput(paste0(prefix, "_name_", i), label = NULL, value = value1,
                            placeholder = "如 UniMod:35")),
    column(4, textInput(paste0(prefix, "_mass_", i), label = NULL,
                        value = if (prefix == "vm" && i <= 2) vm_default(i, 2) else "",
                        placeholder = "如 15.994915")),
    column(4, textInput(paste0(prefix, "_sites_", i), label = NULL,
                        value = if (prefix == "vm" && i <= 2) vm_default(i, 3) else "",
                        placeholder = "如 M / STY / *n"))
  )
}

# ---- 分析参数控件 helper: 「中文 (English)」标签 + 旗标灰色帮助行 + 默认值占位符 ----
# inputId 与 server 端 params_ready/reset_import_state 一一对应, 不得改动
param_hint <- function(text) tags$div(class = "param-hint", text)

# 与 shiny::numericInput 渲染完全一致, 补上其至今缺失的 placeholder 属性 (灰色默认值提示)
num_input <- function(inputId, label, value = NA, min = NA, max = NA, step = NA,
                      width = NULL, placeholder = NULL) {
  v <- if (length(value) != 1 || is.na(value)) "" else format(value, trim = TRUE, scientific = FALSE)
  inputTag <- tags$input(id = inputId, type = "number", class = "shiny-input-number form-control",
                         value = v, `data-update-on` = "change", placeholder = placeholder)
  if (!is.na(min)) inputTag$attribs$min <- min
  if (!is.na(max)) inputTag$attribs$max <- max
  if (!is.na(step)) inputTag$attribs$step <- step
  label_class <- if (is.null(label)) "control-label shiny-label-null" else "control-label"
  div(class = "form-group shiny-input-container", style = htmltools::css(width = htmltools::validateCssUnit(width)),
      tags$label(label, class = label_class, id = paste0(inputId, "-label"), `for` = inputId),
      inputTag)
}

p_num <- function(id, cn, en, flag, value = NA, ph = NULL, min = 0, max = NULL, step = NULL, note = NULL) {
  tagList(
    num_input(id, paste0(cn, " (", en, "):"), value = value, min = min,
              max = if (is.null(max)) NA_real_ else max,
              step = if (is.null(step)) NA_real_ else step, placeholder = ph),
    param_hint(if (is.null(note)) flag else paste0(flag, "; ", note))
  )
}

p_txt <- function(id, cn, en, flag, value = "", ph = "", note = NULL, width = NULL) {
  tagList(
    textInput(id, label = paste0(cn, " (", en, "):"), value = value, placeholder = ph, width = width),
    param_hint(if (is.null(note)) flag else paste0(flag, "; ", note))
  )
}

p_chk <- function(id, cn, en, flag, value = FALSE) {
  checkboxInput(id, label = HTML(sprintf("%s (%s) <span class='flag-hint'>%s</span>", cn, en, flag)),
                value = value)
}

# Windows 风格最小-最大范围组: 一个标签 + [min] — [max] 两个输入框, 留空即用 DIA-NN 默认
p_range <- function(cn, en, id_min, id_max, def_min, def_max, flag) {
  tags$div(class = "range-group",
    tags$label(class = "range-label", paste0(cn, " (", en, ")")),
    tags$div(class = "range-row",
      num_input(id_min, label = NULL, value = NA, min = 0, placeholder = def_min, width = "44%"),
      tags$span(class = "range-dash", "—"),
      num_input(id_max, label = NULL, value = NA, min = 0, placeholder = def_max, width = "44%")
    ),
    param_hint(sprintf("%s; 留空 = 默认 %s–%s", flag, def_min, def_max))
  )
}
# 全局样式 (选择器覆盖任务队列/帮助页, 故由 app.R 在 dashboardBody 引用)
PARAM_CSS_TAG <- tags$style(HTML("      .scrollbox {max-height: 460px; overflow-y: auto; border: 1px solid #d5d8de; border-radius: 3px;
                  padding: 8px; background: #fff;}
      .scrollbox pre {margin: 0; font-size: 12px; white-space: pre-wrap;}
      .smallbox {max-height: 90px; overflow-y: auto; font-size: 11px; background: #f7f8fa;
                 border: 1px solid #e2e5ea; border-radius: 3px; padding: 5px 8px; white-space: pre-wrap;}
      .msg-err {color: #c0392b; font-weight: 600;}
      .flag-hint {color: #93a1b1; font-size: 11px; font-family: Menlo, Consolas, monospace;
                  font-weight: 400; margin-left: 4px; white-space: nowrap;}
      .param-hint {color: #909aa6; font-size: 12px; margin: -10px 0 12px 1px;}
      .range-group {margin-bottom: 14px;}
      .range-group .range-label {display: block; margin-bottom: 5px;}
      .range-row {display: flex; align-items: center;}
      .range-row .shiny-input-container {margin-bottom: 0;}
      .range-group .param-hint {margin-top: 5px;}
      .range-dash {flex: 0 0 auto; margin: 0 8px; color: #6c757d; font-weight: 600;}
"
))

# 「分析参数」盒的六个子标签 (Windows 风格 min-max 成组 + 中英双语标签)
param_tabs_ui <- function() {
  tabsetPanel(id = "param_tabs", type = "tabs",
                tabPanel("常规",
                  br(),
                  fluidRow(
                    column(4,
                      p_num("threads", "线程数", "Threads", "--threads", 16, min = 1, max = 128),
                      p_num("qvalue", "前体 q-value 阈值", "Precursor q-value", "--qvalue",
                            0.01, min = 0, max = 1, step = 0.001),
                      tagList(
                        selectInput("verbose", "日志详细度 (Verbosity):", choices = 0:4, selected = 1),
                        param_hint("--verbose")
                      )
                    ),
                    column(4,
                      p_chk("mbr", "MBR 跨 run 匹配", "Match between runs", "--reanalyse", TRUE),
                      p_chk("rt_prof", "RT/IM 轮廓学习", "RT/IM profiling", "--rt-profiling", TRUE),
                      p_chk("peptidoforms", "peptidoform 置信评分", "Peptidoform scoring", "--peptidoforms", TRUE)
                    ),
                    column(4,
                      p_chk("proteoforms", "proteoform 置信评分", "Proteoform scoring", "--proteoforms", FALSE),
                      p_chk("matrices", "输出定量矩阵", "Output matrices", "--matrices", TRUE),
                      p_chk("indiv_reports", "逐 run 单独报告", "Individual reports", "--individual-reports", FALSE),
                      p_chk("unimod4", "UniMod:4 固定修饰处理", "UniMod:4 handling", "--unimod4", TRUE)
                    )
                  )
                ),
                tabPanel("质量与提取",
                  br(),
                  fluidRow(
                    column(4, p_num("mass_acc", "MS2 质量精度 ppm", "MS2 mass accuracy",
                                    "--mass-acc", NA, ph = "自动", note = "留空 = 自动")),
                    column(4, p_num("mass_acc_ms1", "MS1 质量精度 ppm", "MS1 mass accuracy",
                                    "--mass-acc-ms1", NA, ph = "自动", note = "留空 = 自动")),
                    column(4, p_num("window", "扫描窗口半径", "Window radius",
                                    "--window", NA, ph = "自动", note = "留空 = 自动"))
                  ),
                  fluidRow(
                    column(4, p_num("min_peak", "最小峰高", "Min peak height",
                                    "--min-peak", NA, ph = "自动", note = "留空 = 自动")),
                    column(4, p_num("rt_window", "RT 提取窗口下限 秒", "RT window (sec)",
                                    "--rt-window", NA, ph = "自动", note = "留空 = 自动")),
                    column(4, p_num("im_window", "IM 提取窗口下限", "IM window",
                                    "--im-window", NA, ph = "自动", note = "留空 = 自动"))
                  ),
                  fluidRow(
                    column(4, p_num("quant_qvalue", "定量 q-value", "Quant q-value",
                                    "--quant-qvalue", NA, ph = "0.01", note = "留空 = 默认 0.01",
                                    max = 1, step = 0.001)),
                    column(4, p_num("protein_quant_qvalue", "蛋白定量 q-value", "Protein q-value",
                                    "--protein-quant-qvalue", NA, ph = "0.01", note = "留空 = 默认 0.01",
                                    max = 1, step = 0.001)),
                    column(4, p_num("matrix_qvalue", "矩阵过滤 q-value", "Matrix q-value",
                                    "--matrix-qvalue", NA, note = "留空 = 默认",
                                    max = 1, step = 0.001))
                  ),
                  helpText("以上数值参数留空时保持 DIA-NN 自动优化行为, 不写入命令行。")
                ),
                tabPanel("修饰",
                  br(),
                  fluidRow(
                    column(3, p_num("var_mods_max", "每肽段最大可变修饰数", "Max var mods per peptide",
                                    "--var-mods", 1, min = 0, max = 10)),
                    column(4, p_chk("met_excision", "N 端甲硫氨酸切除", "Met excision", "--met-excision", FALSE)),
                    column(4, p_chk("reannotate", "用 FASTA 重注释谱库", "Reannotate library", "--reannotate", FALSE))
                  ),
                  h5(tags$strong("可变修饰 (Variable modifications)")),
                  param_hint("--var-mod 名称,质量,位点"),
                  fluidRow(
                    column(4, tags$strong("名称 (Name)")), column(4, tags$strong("质量 (Mass)")), column(4, tags$strong("位点 (Sites)"))
                  ),
                  lapply(1:6, function(i) mod_row_ui("vm", i, value1 = vm_default(i, 1))),
                  h5(tags$strong("固定修饰 (Fixed modifications)")),
                  param_hint("--fixed-mod; 留空行忽略"),
                  lapply(1:3, function(i) mod_row_ui("fm", i))
                ),
                tabPanel("FASTA搜索/库构建",
                  br(),
                  fluidRow(
                    column(4,
                      p_chk("fasta_search", "执行 FASTA 酶切搜索", "FASTA search", "--fasta-search", FALSE),
                      helpText("无库(FASTA)分析时必须勾选; 仅用 FASTA 为谱库注释时保持不勾选")
                    ),
                    column(4,
                      p_chk("use_cut", "自定义酶切特异性", "Cut specificity", "--cut", FALSE),
                      conditionalPanel("input.use_cut == 1",
                        tagList(
                          textInput("cut", "酶切特异性 (Specificity):", "K*,R*,!*P"),
                          param_hint("默认 K*,R*,!*P (标准胰酶); Trypsin/P: K*,R*; Lys-C: K*,!*P; 非特异: **")
                        )
                      )
                    ),
                    column(4,
                      p_num("missed_cleavages", "最大漏切位点数", "Missed cleavages",
                            "--missed-cleavages", NA, ph = "1", note = "留空 = 默认 1")
                    )
                  ),
                  br(),
                  fluidRow(
                    column(6, p_range("肽段长度", "Peptide length", "min_pep_len", "max_pep_len",
                                      "7", "30", "--min-pep-len / --max-pep-len")),
                    column(6, p_range("前体 m/z", "Precursor m/z", "min_pr_mz", "max_pr_mz",
                                      "300", "1800", "--min-pr-mz / --max-pr-mz"))
                  ),
                  fluidRow(
                    column(6, p_range("前体电荷", "Precursor charge", "min_pr_charge", "max_pr_charge",
                                      "1", "4", "--min-pr-charge / --max-pr-charge")),
                    column(6, p_range("碎片 m/z", "Fragment m/z", "min_fr_mz", "max_fr_mz",
                                      "200", "1800", "--min-fr-mz / --max-fr-mz"))
                  ),
                  fluidRow(
                    column(4, p_chk("predictor", "深度学习预测谱图/RT/IM", "Deep learning predictor", "--predictor", FALSE)),
                    column(4, p_chk("light_models", "轻量预测模型", "Light models", "--light-models", FALSE)),
                    column(4, p_chk("gen_spec_lib", "生成谱图库", "Generate spectral library", "--gen-spec-lib", FALSE))
                  ),
                  conditionalPanel("input.gen_spec_lib == 1",
                    fluidRow(
                      column(6, p_txt("out_lib", "谱库输出路径", "Library output path",
                                      "--out-lib", "", ph = "输出目录/library.speclib",
                                      note = "留空 = <输出目录>/library.speclib")),
                      column(6, p_num("out_lib_qvalue", "经验谱库 q-value 阈值", "Empirical library q-value",
                                      "--out-lib-qvalue", NA, ph = "0.05", note = "留空 = 默认 0.05",
                                      max = 1, step = 0.01))
                    )
                  )
                ),
                tabPanel("高级",
                  br(),
                  fluidRow(
                    column(3,
                      p_chk("export_quant", "导出 fragment 定量", "Export fragment quant", "--export-quant", FALSE),
                      p_chk("report_decoys", "保留 decoy 报告", "Report decoys", "--report-decoys", FALSE),
                      p_chk("individual_windows", "各 run 独立窗口", "Per-run windows", "--individual-windows", FALSE)
                    ),
                    column(3,
                      p_chk("individual_mass_acc", "各 run 独立质量精度", "Per-run mass accuracy", "--individual-mass-acc", FALSE),
                      p_chk("global_norm", "全局归一化", "Global normalization", "--global-norm", FALSE),
                      p_chk("no_rt_norm", "关闭 RT 归一化", "Disable RT normalization", "--no-rt-norm", FALSE)
                    ),
                    column(3,
                      p_chk("no_prot_norm", "关闭蛋白归一化", "Disable protein normalization", "--no-prot-norm", FALSE),
                      p_chk("high_acc", "定量高精度模式", "High accuracy", "--high-acc", FALSE),
                      p_chk("no_skyline", "不生成 skyline 库", "No skyline library", "--no-skyline", FALSE)
                    ),
                    column(3,
                      p_chk("no_stats", "不生成 stats 文件", "No stats files", "--no-stats", FALSE),
                      p_num("xic", "XIC 提取秒数", "XIC extraction (sec)", "--xic", NA, note = "留空 = 关闭"),
                      p_num("min_corr", "最小峰组相关分数", "Min peak correlation",
                            "--min-corr", NA, ph = "自动", note = "留空 = 自动", max = 1, step = 0.01)
                    )
                  )
                ),
                tabPanel("额外参数",
                  br(),
                  textAreaInput("extra_args", "其他参数 (Additional arguments, 原样追加到命令尾部, 空格分隔):",
                                height = "100px",
                                placeholder = "例如: --cfg /path/to/config.txt --min-fr 3 --loc-factor 40"),
                  helpText("未在以上面板覆盖的参数均可在此填写; 完整参数说明见\"参数速查\"页。")
                )
  )
}
