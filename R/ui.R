# ============================================================
# ui.R — 应用界面 (dashboardPage)
# inputId/DOM/JS 条件为三重契约的一部分 (server + 旗标映射 + e2e), 不得单独改动。
# ============================================================
app_ui <- function(analysis_only = FALSE) {
# v1.12 执行后端: UI 在启动时按解析结果条件渲染 (会话期间不切换)。
# backend_slurm = FALSE 时隐藏分区/集群节点资源等 Slurm 专属控件, 提交按钮与文案改为本地。
backend <- cfg_get("EXEC_BACKEND_RESOLVED") %||% "slurm"
if (!backend %in% c("slurm", "local")) backend <- "slurm"
is_local <- identical(backend, "local")
backend_cn <- if (is_local) "本地单机" else "Slurm 集群"
# v1.15 界面语言: header 右上角下拉切换 (写配置 + 自动刷新页面, 见 app_server)。
# 初始选中值按本次会话解析出的 LANG 渲染; 刷新后 app_ui 以新语言重建全部界面。
lang_cur <- i18n_lang()
lang_menu_item <- tags$li(class = "dropdown",
  tags$a(href = "#", class = "dropdown-toggle", `data-toggle` = "dropdown",
         title = tr_("界面语言"), icon("language"), style = "padding: 13px 14px;"),
  tags$ul(class = "dropdown-menu", style = "padding: 12px 15px; min-width: 175px;",
    tags$li(tags$label(tr_("界面语言"), style = "font-weight: 600; color: #444;")),
    tags$li(selectInput("lang_switch", NULL,
                        choices = c("English" = "en", "中文" = "zh"),
                        selected = lang_cur, width = "140px")),
    tags$li(style = "padding: 6px 2px 0 2px; font-size: 11px; color: #777; white-space: normal;",
            tr_("切换后页面自动刷新一次。"))))
# SIF 运行时版本要求 (apptainer ≥ 1.0 / singularity ≥ 3.0) 的统一文案:
# 先算成 HTML 字符串, 再交给 helpText, 避免多层嵌套把 UI 结构写乱。
sif_min_txt <- sif_min_version_text()
sif_req_panel <- HTML(sprintf(tr_(paste0(
  "<b>版本要求:</b> %s。SIF 是 Singularity 3.0 起的镜像格式, ",
  "2.x (如 conda 里的 2.4.6) 只能读 squashfs/ext3 的 .simg, ",
  "对 .sif 会报 <code>Unknown image format/type</code>; ",
  "候选里标注 <b style='color:#dd4b39'>⚠ 不支持 SIF</b> 的请勿选用。")),
  htmltools::htmlEscape(sif_min_txt)))
sif_req_current <- HTML(sprintf(tr_(paste0(
  "SIF 镜像需要 <b>%s</b>; 低于此版本的 singularity 能执行 <code>--version</code> ",
  "但读不了 .sif, 提交会被拦下。")), htmltools::htmlEscape(sif_min_txt)))
sif_req_chain <- HTML(sprintf(tr_(paste0(
  "验证链: 文件存在/可读 → SIF 魔数 → 运行时版本 (<b>%s</b>) ",
  "→ apptainer inspect → 容器内启动 diann-linux。")), htmltools::htmlEscape(sif_min_txt)))
ui <- dashboardPage(
  dashboardHeader(lang_menu_item, title = span(
    tr_("DIA-NN 控制台"), tags$small(GUI_VERSION),
    if (analysis_only) tags$span(class = "label label-success", tr_("结果分析"))
    else if (is_local) tags$span(class = "label label-success", tr_("本地单机"))
    else tags$span(class = "label label-primary", tr_("Slurm 集群")))),
  dashboardSidebar({
    # shinydashboard 的 sidebarMenu/tabItems 不接受 NULL 元素: 先收集再过滤
    # (analysis_only 模式下隐藏运行管理相关页签)
    an_menu_items <- list(
      if (!analysis_only) menuItem(tr_("提交分析"), tabName = "analysis", icon = icon("play-circle")),
      if (!analysis_only) menuItem(tr_("任务队列"), tabName = "monitor", icon = icon("list-ul")),
      menuItem(tr_("结果分析"), tabName = "downstream", icon = icon("chart-column")),
      if (!analysis_only) menuItem(tr_("参数速查"), tabName = "help", icon = icon("book")),
      if (!analysis_only) menuItem(tr_("更新说明"), tabName = "changelog", icon = icon("history")))
    # id 供 updateTabItems 服务端切页 (结果分析入口联动)
    sidebarMenu(id = "tabs",
                .list = an_menu_items[!vapply(an_menu_items, is.null, logical(1))])
  }),
  dashboardBody({
    an_tab_items <- list(
      # ==================== 提交分析 ====================
      if (!analysis_only) tabItem(tabName = "analysis",
        fluidRow(
          column(12, div(id = "backend_banner", class = if (is_local) "alert alert-success" else "alert alert-info",
            style = "margin: 0 0 10px 0; padding: 8px 12px;",
            HTML(if (is_local) tr_(
              "<b>当前执行后端：本地单机（无 Slurm）</b> — 作业在本 GUI 所在主机直接运行；关闭浏览器不影响作业；日志为 <code>local-&lt;作业ID&gt;.out/.err</code>；并发上限见 LOCAL_MAX_JOBS。")
            else tr_(
              "<b>当前执行后端：Slurm 集群</b> — 作业提交到队列，需排队；日志为 <code>slurm-&lt;作业ID&gt;.out/.err</code>；进度在「任务队列」页查看。"))))
        ),
        fluidRow(
          box(title = tr_("1. apptainer 运行环境"), status = "primary", solidHeader = TRUE, width = 12, collapsible = TRUE,
              column(4,
                selectInput("apptainer_version",
                            tr_("apptainer (自动识别, 共 %d 个):", length(cfg_get("APPTAINER_CHOICES"))),
                            choices = cfg_get("APPTAINER_CHOICES"), selected = cfg_get("APPTAINER_SELECTED")),
                actionButton("refresh_apptainer", tr_("重新扫描"), icon = icon("sync")),
                helpText(tr_("扫描 PATH、APPTAINER_PATHS 与常见安装位置; 多版本按版本号列出。")),
                helpText(sif_req_panel),
                checkboxInput("use_custom_apptainer", tr_("手动指定 apptainer 路径"), FALSE),
                conditionalPanel("input.use_custom_apptainer == 1",
                  textInput("custom_apptainer", tr_("apptainer 可执行文件完整路径:"),
                            placeholder = "/opt/apptainer/bin/apptainer"),
                  actionButton("verify_apptainer", tr_("识别并验证"), icon = icon("check")),
                  uiOutput("apptainer_verify_result")
                )
              ),
              column(4,
                tags$label(tr_("当前生效 apptainer:")), br(),
                verbatimTextOutput("apptainer_display"),
                helpText(tr_("作业脚本优先使用该路径; 计算节点不可见时按 APPTAINER_PATHS → PATH → module 回退。")),
                helpText(sif_req_current)
              ),
              column(4,
                tags$label(tr_("运行环境自检 (GUI 节点):")), br(),
                uiOutput("apt_check_display")
              )
          )
        ),
        fluidRow(
          box(title = tr_("2. DIA-NN 版本 (sif 镜像)"), status = "primary", solidHeader = TRUE, width = 12, collapsible = TRUE,
              column(6,
                selectInput("sif_version",
                            tr_("镜像 (扫描 SIF_DIRS 下所有 *.sif, 文件名无关):"),
                            choices = cfg_get("sif_choices"), selected = cfg_get("sif_selected")),
                helpText(tr_("版本来自容器内实测 (选中未识别镜像会自动识别); 若下拉为空请检查 config.R 中的 SIF_DIRS。")),
                checkboxInput("use_custom_sif", tr_("浏览/手动指定其他镜像"), FALSE),
                conditionalPanel("input.use_custom_sif == 1",
                  shinyFilesButton("sif_pick", tr_("选择 SIF 镜像文件"), tr_("在数据卷内选择 .sif 镜像 (单个)"), multiple = FALSE),
                  textInput("custom_sif", tr_("sif 文件完整路径 (选择或手动输入):"), placeholder = "/path/to/diann-x.y.z.sif"),
                  helpText(tr_("镜像须位于计算节点可见的共享存储; 浏览范围限于数据卷, 之外的路径请手动输入。"))
                )
              ),
              column(6,
                tags$label(tr_("当前生效镜像:")), br(),
                uiOutput("sif_version_info"),
                verbatimTextOutput("sif_display"),
                actionButton("verify_sif", tr_("验证镜像可用性 (快速)"), icon = icon("check-circle"), width = "100%",
                             style = "color:#fff; background-color:#00a65a; border-color:#008d4d"),
                actionButton("verify_sif_deep", tr_("识别版本并深度验证 (容器内启动, 较慢)"), icon = icon("microscope"), width = "100%"),
                actionButton("sif_identify_all", tr_("识别所有未识别镜像"), icon = icon("tasks"), width = "100%"),
                conditionalPanel("output.sif_identify_progress.length > 0 && output.sif_identify_progress != ''",
                  actionButton("sif_identify_cancel", tr_("取消识别"), icon = icon("stop"), width = "100%",
                               style = "color:#fff; background-color:#dd4b39; border-color:#d73925"),
                  verbatimTextOutput("sif_identify_progress")
                ),
                helpText(sif_req_chain),
                uiOutput("sif_verify_result")
              )
          )
        ),
        fluidRow(
          box(title = tr_("3. 文件与数据库"), status = "primary", solidHeader = TRUE, width = 12,
              column(3,
                radioButtons("raw_mode", tr_("RAW 输入方式:"), inline = TRUE,
                             choices = setNames(c("files", "dir"), c(tr_("选择文件"), tr_("扫描目录")))),
                conditionalPanel("input.raw_mode == 'files'",
                  shinyFilesButton("raw_files", tr_("选择 RAW 文件"), tr_("选择待分析的原始文件 (可多选)"), multiple = TRUE)
                ),
                conditionalPanel("input.raw_mode == 'dir'",
                  shinyDirButton("raw_dir_btn", tr_("选择 RAW 目录"), tr_("选择包含原始文件的目录 (递归扫描)")),
                  verbatimTextOutput("raw_dir_display")
                ),
                verbatimTextOutput("raw_path_display"),
                helpText(tr_("注意: DIA-NN 会在 RAW 目录生成 *.raw.quant 缓存并自动复用, 同一目录混用不同谱库/版本的分析可能报 library size mismatch, 必要时删除 *.raw.quant"))
              ),
              column(3,
                shinyFilesButton("lib_file", tr_("选择光谱库"), tr_("选择光谱库 (可选, .speclib/.parquet/.tsv/.msp/.sptxt)"), multiple = FALSE),
                verbatimTextOutput("lib_path_display"),
                helpText(tr_("与 FASTA 至少提供一个"))
              ),
              column(3,
                shinyFilesButton("fasta_file", tr_("选择 FASTA"), tr_("选择蛋白序列库 (可多选, 无库分析时必选)"), multiple = TRUE),
                verbatimTextOutput("fasta_path_display"),
                checkboxInput("cont_exclude", tr_("启用污染物扣除 (cRAP)"), FALSE),
                conditionalPanel("input.cont_exclude == 1",
                  textInput("cont_tag", tr_("排除标签 (--cont-quant-exclude):"), "cRAP-"),
                  helpText(tr_("自动附加内置 cRAP 污染物库 (125 条) 并从定量中排除该类蛋白"))
                )
              ),
              column(3,
                shinyFilesButton("ref_file", tr_("选择校准库"), tr_("选择专用校准谱库 --ref (可选)"), multiple = FALSE),
                verbatimTextOutput("ref_path_display"),
                helpText(tr_("可选: 仅用于校准的小型谱库"))
              )
          )
        ),
        fluidRow(
          box(title = tr_("4. 输出设置"), status = "success", solidHeader = TRUE, width = 4,
              shinyDirButton("out_dir", tr_("选择输出目录"), tr_("选择结果存放目录")),
              verbatimTextOutput("out_path_display"),
              textInput("report_name", tr_("主报告文件名 (自动加 .tsv):"), "report"),
              shinyDirButton("temp_dir", tr_("选择临时目录 --temp (可选)"), tr_("选择临时目录")),
              verbatimTextOutput("temp_path_display"),
              checkboxInput("convert_only", tr_("仅执行 RAW→DIA 转换 (--convert)"), FALSE),
              helpText(tr_("勾选后忽略分析参数; 转换后的 .dia 文件保存在 RAW 文件所在目录"))
          ),
          box(title = tr_("5. 分析参数"), status = "warning", solidHeader = TRUE, width = 8,
              fluidRow(
                column(4, actionButton("preset_lib", tr_("预设: FASTA 生成预测库"), icon = icon("magic"), width = "100%")),
                column(4, actionButton("preset_convert", tr_("预设: RAW 转 DIA (仅转换)"), icon = icon("file-export"), width = "100%")),
                column(4, helpText(tr_("预设仅切换常用开关组合, 其余参数仍可手动调整。")))
              ),
              br(),
              param_tabs_ui()
          )
        ),
        fluidRow(
          box(title = tr_("命令导入 (自动识别并填充参数)"), status = "info", solidHeader = TRUE, width = 12,
              collapsible = TRUE, collapsed = TRUE,
              column(8,
                textAreaInput("import_cmd",
                              tr_("粘贴 DIA-NN 命令 (支持 Windows GUI 生成的命令、本页预览的 %s 脚本):",
                                  if (is_local) tr_("本地") else "Slurm"),
                              height = "90px",
                              placeholder = "diann.exe --f C:\\data\\run.raw --lib C:\\lib.parquet --qvalue 0.01 --matrices ...")
              ),
              column(4,
                actionButton("import_btn", tr_("解析并填充参数"), icon = icon("download"), class = "btn-primary", width = "100%"),
                checkboxInput("use_imported_raws", tr_("覆盖 RAW 文件 (用导入路径)"), FALSE),
                checkboxInput("use_imported_raw_dir", tr_("覆盖 RAW 目录 (用导入路径)"), FALSE),
                checkboxInput("use_imported_lib", tr_("覆盖光谱库 library (用导入路径)"), FALSE),
                checkboxInput("use_imported_fasta", tr_("覆盖 FASTA (用导入路径)"), FALSE),
                checkboxInput("use_imported_ref", tr_("覆盖校准库 ref (用导入路径)"), FALSE),
                checkboxInput("use_imported_out", tr_("覆盖输出目录 (用导入路径)"), FALSE),
                checkboxInput("use_imported_temp", tr_("覆盖临时目录 (用导入路径)"), FALSE)
              ),
              verbatimTextOutput("import_result")
          )
        ),
        fluidRow(
          box(title = if (is_local) tr_("6. 运行资源 (本地)") else tr_("6. Slurm 资源"), status = "info", solidHeader = TRUE, width = 12,
              column(3, textInput("job_name", tr_("任务名称:"), "DIANN_Task")),
              if (!is_local) {
                column(3, selectInput("partition", tr_("计算分区:"),
                                      choices = cfg_get("SLURM_PARTITIONS"),
                                      selected = cfg_get("SLURM_PARTITIONS")[1]))
              },
              column(3, if (is_local) {
                numericInput("mem_gb", tr_("内存建议 (GB, 仅提示不可强制):"), 64, min = 1, max = 4096)
              } else {
                numericInput("mem_gb", tr_("内存 (GB):"), 64, min = 1, max = 4096)
              }),
              column(3, numericInput("time_h", if (is_local) tr_("超时时限 (小时, 留空=不限):") else tr_("时限 (小时, 留空=不限):"), NA, min = 1)),
              helpText(if (is_local) {
                tr_("本地模式直接在 GUI 所在主机运行 (无排队/无 Slurm 记账); 线程数由「5. 分析参数 → 常规 → 线程数」决定, 时限到点由运行器 timeout 强制终止。")
              } else {
                tr_("CPU 核数不在此设置: Slurm 的 --cpus-per-task 与 DIA-NN 的 --threads 同源, 由「5. 分析参数 → 常规 → 线程数」决定。")
              })
          )
        ),
        fluidRow(
          box(title = if (is_local) tr_("7. 命令预览与提交 (本地执行)") else tr_("7. 命令预览与提交 (Slurm 提交)"),
              status = "danger", solidHeader = TRUE, width = 12,
              fluidRow(
                column(4,
                  textInput("notify_email", tr_("邮箱通知 (可选):"), placeholder = "someone@126.com, someone2@126.com"),
                  helpText(tr_("作业结束时自动发送邮件, 含项目简介与结果简介; 多个邮箱用英文逗号分隔。"),
                           tr_("需在服务器配置邮件凭据与 python3 (未配置时提交会提示, 不影响作业)。"))
                ),
                column(8,
                  textAreaInput("project_desc", tr_("项目简介 (可选, 随完成邮件发送):"),
                                height = "70px",
                                placeholder = tr_("例如: 小鼠单细胞 DIA 数据, 考察 XX 处理组的蛋白组差异…"))
                )
              ),
              fluidRow(
                column(8,
                  uiOutput("validation_msgs"),
                  tags$div(class = "scrollbox", verbatimTextOutput("preview"))
                ),
                column(4,
                  actionButton("submit_job", if (is_local) tr_("提交本地任务") else tr_("提交 Slurm 任务"),
                               icon = icon("paper-plane"),
                               class = "btn-lg btn-success", width = "100%"),
                  br(), br(),
                  if (is_local) {
                    helpText(tr_("提交前请确认上方校验提示为空、命令预览符合预期。"),
                             tr_("本地脚本将保存到 输出目录/diann_gui_scripts/ 下, stdout/stderr 日志为输出目录下 local-<任务ID>.out/.err;"),
                             tr_("作业脱离浏览器会话运行, 关闭页面不影响执行。"))
                  } else {
                    helpText(tr_("提交前请确认上方校验提示为空、命令预览符合预期。"),
                             tr_("Slurm 脚本将保存到 输出目录/diann_gui_scripts/ 下, stdout/stderr 日志为输出目录下 slurm-<任务ID>.out/.err。"))
                  }
                )
              )
          )
        )
      ),

      # ==================== 任务队列 ====================
      if (!analysis_only) tabItem(tabName = "monitor",
        fluidRow(
          column(12, div(id = "backend_banner_monitor",
                         class = if (is_local) "alert alert-success" else "alert alert-info",
                         style = "margin: 0 0 10px 0; padding: 8px 12px;",
                         HTML(if (is_local) tr_(
                           "<b>当前执行后端：本地单机（无 Slurm）</b> — 本地作业状态来自本机状态文件，无 Slurm 记账；日志为 <code>local-&lt;作业ID&gt;.out</code>。")
                         else tr_(
                           "<b>当前执行后端：Slurm 集群</b> — 队列/记账数据来自 squeue/sacct；日志为 <code>slurm-&lt;作业ID&gt;.out</code>。"))),
                 uiOutput("local_state_note"))
        ),
        if (!is_local) {
          fluidRow(
            box(title = tr_("集群节点资源 (sinfo)"), status = "info", solidHeader = TRUE, width = 12,
                tableOutput("sinfo_table")
            )
          )
        },
        fluidRow(
          box(title = if (is_local) tr_("本地运行任务") else tr_("运行队列 (squeue)"),
              status = "primary", solidHeader = TRUE, width = 12,
              checkboxInput("auto_refresh", tr_("自动刷新 (10 秒)"), TRUE),
              actionButton("refresh_q", tr_("立即刷新"), icon = icon("sync")),
              tags$div(class = "scrollbox", verbatimTextOutput("squeue_output"))
          )
        ),
        fluidRow(
          box(title = if (is_local) tr_("近期历史 (本地作业, 最近 300 条)") else tr_("近期历史 (sacct, 最近一天)"),
              status = "primary", solidHeader = TRUE, width = 12, collapsible = TRUE,
              tableOutput("sacct_table"),
              helpText(if (is_local) {
                tr_("作业ID: 本地作业号 | 作业名: 提交时的任务名称 | 状态: 作业结果 (已完成/运行中/失败/超时/已取消等) | 运行时长: 作业实际运行时间 | 结束时间: 作业退出时刻")
              } else {
                tr_("作业ID: Slurm 作业号 | 作业名: 提交时的任务名称 | 状态: 作业结果 (已完成/运行中/排队中/失败/超时/已取消等) | 运行时长: 作业实际运行时间 | 结束时间: 作业退出时刻")
              })
          )
        ),
        fluidRow(
          box(title = tr_("取消作业"), status = "danger", solidHeader = TRUE, width = 4,
              numericInput("cancel_id", tr_("作业 ID:"), NA),
              actionButton("cancel_btn", if (is_local) tr_("取消该作业") else tr_("scancel 取消该作业"),
                           icon = icon("ban"), class = "btn-danger", width = "100%")
          ),
          box(title = if (is_local) tr_("运行日志查看 (local-<ID>.out 尾部)") else tr_("运行日志查看 (slurm-<ID>.out 尾部)"),
              status = "warning", solidHeader = TRUE, width = 8,
              fluidRow(
                column(4, numericInput("log_id", tr_("作业 ID:"), NA)),
                column(8,
                  shinyDirButton("log_dir_btn", tr_("指定日志目录 (可选, 留空自动定位)"), tr_("选择包含日志的目录")),
                  verbatimTextOutput("log_dir_display")
                )
              ),
              actionButton("view_log", tr_("查看日志 (尾部 120 行)"), icon = icon("file-alt")),
              tags$div(class = "scrollbox", verbatimTextOutput("log_output"))
          )
        ),
        fluidRow(
          box(title = tr_("本会话提交记录"), status = "info", solidHeader = TRUE, width = 12,
              tableOutput("jobs_table"),
              uiOutput("mail_gate_banner"),   # v1.14.3: 邮件停用常驻横幅 (直达监控页的用户也可见)
              verbatimTextOutput("notify_status")
          )
        ),
        fluidRow(
          box(title = tr_("结果分析入口 (已完成作业的蛋白矩阵)"), status = "success",
              solidHeader = TRUE, width = 12,
              fluidRow(
                column(4, selectInput("analysis_job", tr_("已完成作业 (提交记录):"),
                                      choices = "", selected = NULL)),
                column(8, uiOutput("analysis_matrix_ui"))
              ),
              actionButton("goto_analysis", tr_("进入下游分析"), icon = icon("chart-column"),
                           class = "btn-primary"),
              helpText(tr_("从提交记录定位已完成作业输出目录内的 *matrix*.tsv 蛋白矩阵"),
                       tr_("(DIA-NN --matrices 导出; pg_matrix 优先), 一键带入「结果分析」页。"),
                       tr_("提交记录为空或作业较旧时, 请直接在「结果分析」页填写矩阵路径。"))
          )
        )
      ),

      # ==================== 结果分析 (v1.14 下游分析模块) ====================
      tabItem(tabName = "downstream",
        analysis_ui("analysis")
      ),

      # ==================== 参数速查 ====================
      if (!analysis_only) tabItem(tabName = "help",
        box(title = tr_("DIA-NN 命令行参数速查"), status = "primary", solidHeader = TRUE, width = 12,
            verbatimTextOutput("doc_path_display"),
            tags$div(class = "scrollbox", uiOutput("param_ref"))
        )
      ),

      # ==================== 更新说明 ====================
      if (!analysis_only) tabItem(tabName = "changelog",
        fluidRow(
          box(title = tr_("DIA-NN 版本说明 (含实测结论)"), status = "info", solidHeader = TRUE, width = 12,
              uiOutput("version_notes"),
              tags$strong(tr_("本机已扫描到的 sif 镜像:")),
              tableOutput("sif_table")
          )
        ),
        fluidRow(
          box(title = tr_("DIA-NN 2.0 系列官方更新日志 (Release Notes 原文, 新的在前)"), status = "info",
              solidHeader = TRUE, width = 12, collapsible = TRUE, collapsed = TRUE,
              uiOutput("diann_release_notes")
          )
        ),
        fluidRow(
          box(title = tr_("GUI 更新日志 (当前 v%s)",
                              utils::packageVersion("diann.gui")), status = "primary",
              solidHeader = TRUE, width = 12,
              uiOutput("gui_changelog")
          )
        )
      )
    )
    tagList(tags$head(PARAM_CSS_TAG),
            do.call(tabItems, an_tab_items[!vapply(an_tab_items, is.null, logical(1))]),
            # v1.15 语言切换: server 写完配置后发此消息, 浏览器整页重载,
            # 新会话的 app_ui 按新 LANG 重建 (语言在会话期间不热切换)。
            tags$script(HTML(paste0(
              "Shiny.addCustomMessageHandler('diann_gui_reload', function(msg) { ",
              "location.reload(); });"))))
  })
)

# ============================================================
# Server
# ============================================================
}
