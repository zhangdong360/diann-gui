# ============================================================
# ui-analysis.R — 结果分析页 (下游分析模块) UI 与样式
#
# 移植自 mass_analysis (ProteoDIA Studio) 的 6 个页签, 改造为
# diann.gui dashboard 的一个 menuItem:
#   数据来源/全局参数 (顶部两框) + 6 个子页签
#   ① 数据与分组 ② 预处理 ③ QC 可视化 ④ 差异分析 ⑤ 功能富集 ⑥ 生成报告
#
# 与上传式 mass_analysis 的差异: 数据经 服务端路径 直接读取 (HPC 共享存储),
# 不使用 fileInput 上传控件。
# 图形预览红线见 R/analysis-plot.R 头注 (SVG data URI, 勿改回 renderPlot)。
# ============================================================

ANALYSIS_CSS_TAG <- tags$style(HTML(paste0(
  # 图形容器: 宽度撑满, 高度按 SVG viewBox 自适应; 勿加 max-height/aspect-ratio
  ".an-plot-box{background:#fff;border:1px solid #e3ebf2;border-radius:6px;padding:8px;margin-bottom:6px;width:100%}",
  ".an-plot-box img{display:block;width:100%;height:auto}",
  ".an-plot-caption{font-size:12px;color:#78909c;margin:2px 0 12px}",
  # 卡片/提示 (与报告模板主色一致)
  ".an-card{background:#fff;border:1px solid #dde5ec;border-radius:8px;padding:14px 16px;margin-bottom:14px}",
  ".an-card h4{font-size:14.5px;font-weight:700;color:#0b5f9e;margin:0 0 8px}",
  ".an-hint{font-size:12.5px;color:#78909c;line-height:1.6}",
  ".an-ok{font-size:12.5px;color:#2e7d32;background:#e8f5e9;border:1px solid #c8e6c9;border-radius:5px;padding:7px 10px;margin-bottom:8px}",
  ".an-err{font-size:12.5px;color:#c62828;background:#ffebee;border:1px solid #ffcdd2;border-radius:5px;padding:7px 10px;margin-bottom:8px}",
  ".an-warn-ul{list-style:none;padding-left:0;margin:0 0 8px}",
  ".an-warn-ul li{font-size:12.5px;color:#b26a00;background:#fff8e1;border-left:3px solid #ffb300;border-radius:3px;padding:6px 10px;margin-bottom:6px}",
  ".an-stat-row{display:flex;flex-wrap:wrap;gap:10px;margin:6px 0 12px}",
  ".an-stat-card{flex:1 1 120px;min-width:120px;background:#f4f9fd;border:1px solid #d6e6f2;border-radius:8px;padding:10px 12px;text-align:center}",
  ".an-stat-card .num{font-size:22px;font-weight:700;color:#0b5f9e;line-height:1.1}",
  ".an-stat-card .label{font-size:12px;color:#546e7a;margin-top:3px;font-weight:600}",
  ".an-mod-params{background:#f7fafc;border:1px solid #e3ebf2;border-radius:6px;padding:10px 12px 0;margin-bottom:12px}",
  ".an-mod-params label{font-size:12.5px;font-weight:600;color:#37474f}",
  ".an-mono{font-family:Consolas,Menlo,monospace;font-size:12px;background:#f5f7f9;border:1px solid #e3ebf2;border-radius:4px;padding:6px 9px;word-break:break-all;color:#455a64}",
  ".an-report-preview{width:100%;height:760px;border:1px solid #dde5ec;border-radius:6px}"
)))

analysis_ui <- function(id) {
  ns <- NS(id)
  # DT 仅在 Suggests: 缺包时隐藏可编辑表 (模块侧提供粘贴式分组兜底)
  dt_ok <- requireNamespace("DT", quietly = TRUE)
  tagList(
    ANALYSIS_CSS_TAG,
    # ---- 依赖门禁提示 (缺包时置顶引导) ----
    uiOutput(ns("deps_alert")),

    fluidRow(
      # ---- 1. 数据来源 ----
      box(title = tr_("1. 数据来源 (蛋白定量矩阵)"), status = "primary", solidHeader = TRUE, width = 6,
        radioButtons(ns("source"), tr_("矩阵格式:"),
                     choices = setNames(c("diann", "spectronaut"),
                                        c(tr_("DIA-NN（pg_matrix）"), tr_("Spectronaut（PG.* 矩阵）"))),
                     selected = "diann", inline = TRUE),
        shinyFilesButton(ns("matrix_pick"), tr_("浏览服务器文件"), tr_("选择蛋白定量矩阵 (tsv/txt/csv)"),
                         multiple = FALSE),
        textInput(ns("matrix_path"), tr_("矩阵文件完整路径:"),
                  placeholder = "/path/to/pg_matrix.tsv"),
        actionButton(ns("matrix_load"), tr_("读取矩阵"), icon = icon("file-import"),
                     class = "btn-primary"),
        uiOutput(ns("matrix_info")),
        helpText(tr_("数据在服务端共享存储上直接读取 (不上传); DIA-NN 作业完成后可在"),
                 tr_("「任务队列」页一键带入本页。"))
      ),
      # ---- 2. 全局参数 ----
      box(title = tr_("2. 全局参数"), status = "warning", solidHeader = TRUE, width = 6,
        fluidRow(
          column(6, numericInput(ns("min_detect_frac"), tr_("低检出过滤 (检出率下限)"),
                                 value = 0.5, min = 0, max = 1, step = 0.05)),
          column(6, numericInput(ns("min_group_detect"), tr_("分组内最少检测样本数 (0=不启用)"),
                                 value = 0, min = 0, step = 1))
        ),
        radioButtons(ns("impute_method"), tr_("缺失值处理方法:"),
                     choiceNames = list(tr_("不填补 (仅 QC)"), tr_("LoD 左截断高斯 (MNAR)"),
                                        tr_("KNN (MAR)"), tr_("seqKNN 顺序 KNN")),
                     choiceValues = list("none", "mnar", "mar", "seq"),
                     selected = "mnar", inline = TRUE),
        helpText(tr_("LoD: 检测限左删失 (逐样本列, 偏移 1.8 SD / 缩放 0.3 SD / 种子 42);"),
                 tr_("选「不填补」时差异分析与功能富集自动停用。")),
        uiOutput(ns("control_ui")),
        selectInput(ns("species"), tr_("物种 (功能富集注释库):"),
                    choices = setNames(c("auto", "human", "mouse", "rat", "zebrafish"),
                                       c(tr_("自动检测"), "Homo sapiens",
                                         "Mus musculus", "Rattus norvegicus",
                                         tr_("Danio rerio（斑马鱼）"))),
                    selected = "auto"),
        checkboxGroupInput(ns("modules"), tr_("分析模块 (数据预处理始终执行):"),
                           choices = setNames(c("qc", "de", "enrich"),
                                              c(tr_("QC 可视化"), tr_("limma 差异分析"),
                                                tr_("GO/KEGG 功能富集"))),
                           selected = c("qc", "de"), inline = TRUE)
      )
    ),

    tabsetPanel(id = ns("an_tabs"),
      # ---- ① 数据与分组 ----
      tabPanel(tr_("① 数据与分组"),
        uiOutput(ns("data_page")),
        div(class = "an-card",
          h4(tr_("分组设置")),
          fluidRow(
            column(7, uiOutput(ns("infer_status"))),
            column(5, div(style = "text-align:right;padding-top:4px;",
              actionButton(ns("grp_apply"), tr_("应用分组"), class = "btn-primary btn-sm",
                           icon = icon("check")),
              actionButton(ns("grp_reset"), tr_("恢复自动推断"), class = "btn-sm",
                           icon = icon("rotate-left"))))
          ),
          div(class = "an-hint", tr_("双击「样本名」或「组名」单元格即可修改; 改完点「应用分组」生效。"),
              tr_("样本多时可点「批量填入分组…」从 Excel 粘贴。")),
          uiOutput(ns("dt_gate")),
          if (dt_ok) DT::DTOutput(ns("group_table")),
          div(style = "text-align:right;",
              actionButton(ns("open_group_paste"), tr_("批量填入分组…"), class = "btn-sm",
                           icon = icon("wand-magic-sparkles")))
        ),
        div(class = "an-card",
          h4(tr_("批次设置 (可选 ComBat 去批次)")),
          checkboxInput(ns("use_combat"), tr_("启用 ComBat 去批次校正"), value = FALSE),
          uiOutput(ns("combat_block"))
        ),
        div(class = "an-card",
          h4(tr_("数据预览 (前 30 行)")),
          if (dt_ok) DT::DTOutput(ns("preview"))
        )
      ),
      # ---- ② 预处理 ----
      tabPanel(tr_("② 预处理"),
        uiOutput(ns("prep_page")),
        div(class = "an-card", h4(tr_("处理明细")), uiOutput(ns("prep_stats"))),
        div(class = "an-card", h4(tr_("处理告警")), uiOutput(ns("prep_warnings"))),
        div(class = "an-card",
          h4(tr_("缺失机制诊断 (平均丰度 vs 缺失率)")), uiOutput(ns("prep_missing")),
          div(class = "an-plot-caption",
              tr_("低丰度蛋白缺失率偏高 (左图负相关、右图箱体左移) 属 MNAR, 适合 LoD 插补。"))),
        div(class = "an-card",
          h4(tr_("归一化前后强度分布")), uiOutput(ns("prep_normbox")))
      ),
      # ---- ③ QC 可视化 ----
      tabPanel(tr_("③ QC 可视化"),
        div(class = "an-mod-params",
          fluidRow(
            column(4, numericInput(ns("cor_min"), tr_("相关性热图色阶下限"),
                                   value = 0.8, min = -1, max = 1, step = 0.01)),
            column(4, numericInput(ns("cv_bins"), tr_("QC 直方图分箱数 (检出频率/缺失率分布)"),
                                   value = 40, min = 10, max = 100, step = 5))
          )
        ),
        uiOutput(ns("qc_gate")),
        uiOutput(ns("qc_actions")),
        uiOutput(ns("qc_figures")),
        uiOutput(ns("qc_stats"))
      ),
      # ---- ④ 差异分析 ----
      tabPanel(tr_("④ 差异分析"),
        div(class = "an-mod-params",
          fluidRow(
            column(2, numericInput(ns("de_logFC"), tr_("|log2FC| 阈值"), value = 1, step = 0.1)),
            column(2, numericInput(ns("de_pval"), tr_("P 值阈值"), value = 0.05, step = 0.005)),
            column(2, selectInput(ns("de_padj"), tr_("P 值校正"),
                                  choices = setNames(c("BH", "none"), c("BH", tr_("未校正 (原始 P)"))))),
            column(2, numericInput(ns("de_topn_label"), tr_("火山图标注数"), value = 12, min = 0)),
            column(2, numericInput(ns("de_heatmap_max"), tr_("热图最多蛋白"), value = 200, min = 10)),
            column(2, numericInput(ns("de_topn_box"), tr_("关键蛋白箱线数"), value = 9, min = 1))
          )
        ),
        uiOutput(ns("de_gate")),
        uiOutput(ns("de_content"))
      ),
      # ---- ⑤ 功能富集 ----
      tabPanel(tr_("⑤ 功能富集"),
        div(class = "an-mod-params",
          fluidRow(
            column(2, numericInput(ns("en_pval"), tr_("pvalue 阈值"), value = 0.05, step = 0.005)),
            column(2, numericInput(ns("en_qval"), tr_("qvalue 阈值"), value = 0.2, step = 0.05)),
            column(2, selectInput(ns("en_padj"), tr_("P 值校正"),
                                  choices = setNames(c("BH", "none"), c("BH", tr_("未校正 (原始 P)"))))),
            column(2, numericInput(ns("en_minsig"), tr_("最少显著蛋白数"), value = 5, min = 0)),
            column(2, selectInput(ns("en_kegg"), tr_("KEGG 数据源"),
                                  choices = setNames(c("local", "online"),
                                                     c(tr_("本地 KEGG.db"), tr_("在线 KEGG (需联网)"))),
                                  selected = "local")),
            column(2, checkboxInput(ns("en_use_kegg"), tr_("启用 KEGG"), value = TRUE))
          )
        ),
        uiOutput(ns("enrich_gate")),
        uiOutput(ns("enrich_content"))
      ),
      # ---- ⑥ 生成报告 ----
      tabPanel(tr_("⑥ 生成报告"),
        div(class = "an-card",
          h4(tr_("生成 HTML 报告")),
          uiOutput(ns("report_ready")),
          fluidRow(
            column(6,
              shinyDirButton(ns("report_dir_pick"), tr_("浏览目录"), tr_("选择报告生成位置")),
              textInput(ns("report_dir"), tr_("报告输出目录 (留空 = ~/diann_gui_analysis_reports):"),
                        placeholder = "/path/to/output_dir"),
              verbatimTextOutput(ns("report_dir_display"))
            ),
            column(6,
              actionButton(ns("report_build"), tr_("生成报告"), class = "btn-primary",
                           icon = icon("file-code")),
              uiOutput(ns("report_actions"))
            )
          ),
          div(class = "an-hint",
              tr_("报告在服务端生成 (report.html + 图形 + 结果表 + analysis_params.json);"),
              tr_("「下载报告 (zip)」由浏览器保存到本机。"))
        ),
        uiOutput(ns("report_result"))
      )
    )
  )
}
