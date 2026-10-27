# doctor(): 运行环境自检 (全部注入, 不依赖真实集群/包)

# CI runner (GitHub ubuntu-latest) 上没有 Slurm 命令: 断言 "ok" 的用例一律用
# 临时可执行文件注入 — doctor 只检查 非空 + 可执行位 (file.access), 与具体路径无关。
# 此前硬编码 /usr/bin/sbatch 等使 v1.12 起的 CI 在 GitHub runner 上恒红 (本地有
# Slurm 故全绿) — 环境耦合测试, 予以根治。
mk_fake_slurm <- function(...) {
  d <- tempfile("fakeslurm"); dir.create(d, showWarnings = FALSE)
  out <- character(0)
  for (nm in c(...)) {
    p <- file.path(d, nm)
    writeLines("#!/bin/sh", p)
    Sys.chmod(p, "0755")
    out <- c(out, setNames(p, nm))
  }
  out
}

empty_cands <- function() {
  data.frame(path = character(0), kind = character(0), source = character(0),
             version = character(0), ok = logical(0), checked_at = numeric(0),
             stringsAsFactors = FALSE)
}

run_doctor <- function(...) {
  suppressMessages(capture.output(df <- diann.gui::doctor(...)))
  df
}

test_that("doctor 汇总检查项并正确分级", {
  d <- tempfile("dosif"); dir.create(d, showWarnings = FALSE)
  dir.create(d, showWarnings = FALSE)
  writeLines("x", file.path(d, "diann-2.7.0.sif"))

  slurm <- mk_fake_slurm("sbatch", "squeue", "sacct", "sinfo", "scontrol")
  cands <- data.frame(path = "/opt/ap/bin/apptainer", kind = "apptainer", source = "common",
                      version = "1.4.5", ok = TRUE, checked_at = 1, stringsAsFactors = FALSE)
  df <- run_doctor(apptainer_cands = cands, partitions = "compute", slurm_cmds = slurm,
                   sif_dirs = d, mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                   backend = "slurm", deps = character(0))

  expect_s3_class(df, "data.frame")
  expect_true(all(c("check", "status", "detail") %in% names(df)))
  expect_equal(df$status[df$check == "apptainer"], "ok")
  expect_equal(df$status[df$check == "Slurm 分区"], "ok")
  expect_equal(df$status[df$check == "SIF 镜像"], "ok")
  expect_equal(df$status[df$check == "邮件配置"], "warn")
  expect_equal(df$status[df$check == "状态目录"], "ok")
  expect_equal(df$status[df$check == "Slurm 命令 sbatch"], "ok")
  expect_false(any(df$status == "fail"))
})

test_that("doctor 报告缺失的 Slurm 命令与不可写状态目录为 fail", {
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                   slurm_cmds = setNames(c("", mk_fake_slurm("squeue")["squeue"]),
                                         c("sbatch", "squeue")),
                   sif_dirs = character(0), mail_conf = "/nonexistent/mail.txt",
                   state_dir = "/nonexistent/state/dir", backend = "slurm", deps = character(0))
  expect_equal(df$status[df$check == "Slurm 命令 sbatch"], "fail")
  expect_equal(df$status[df$check == "Slurm 命令 squeue"], "ok")
  expect_equal(df$status[df$check == "Slurm 分区"], "warn")
  expect_equal(df$status[df$check == "apptainer"], "warn")
  expect_equal(df$status[df$check == "状态目录"], "fail")
})

test_that("doctor 对过宽的邮件配置权限给出警告, 600 时为 ok", {
  d <- tempfile("domail"); dir.create(d, showWarnings = FALSE)
  dir.create(d, showWarnings = FALSE)
  mc <- file.path(d, "mail_config.txt")
  writeLines("smtp_host=x", mc)
  Sys.chmod(mc, "0644")
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                   slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                   mail_conf = mc, state_dir = tempdir(), backend = "slurm", deps = character(0))
  expect_equal(df$status[df$check == "邮件配置"], "warn")
  expect_match(df$detail[df$check == "邮件配置"], "600")

  Sys.chmod(mc, "0600")
  df2 <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                    slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                    mail_conf = mc, state_dir = tempdir(), backend = "slurm", deps = character(0))
  expect_equal(df2$status[df2$check == "邮件配置"], "ok")
})

# ---------- v1.12: 执行后端分级 (slurm / local) ----------

loc_cmds <- function(setsid = "/usr/bin/setsid") {
  c(setsid = setsid, nohup = "/usr/bin/nohup", timeout = "/usr/bin/timeout", bash = "/bin/bash")
}

test_that("doctor(backend='local'): Slurm 项降级为 na, 本地原语与 /proc 为 ok", {
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                   slurm_cmds = mk_fake_slurm("sbatch", "squeue"),
                   sif_dirs = character(0), mail_conf = "/nonexistent/mail.txt",
                   state_dir = tempdir(), backend = "local",
                   local_cmds = loc_cmds(), deps = character(0))
  expect_equal(df$status[df$check == "执行后端"], "ok")
  expect_match(df$detail[df$check == "执行后端"], "本地单机")
  # v1.13: 本地模式 Slurm 组合并为一行 na
  expect_equal(df$status[df$check == "Slurm 依赖"], "na")
  expect_match(df$detail[df$check == "Slurm 依赖"], "本地模式未启用")
  expect_false(any(grepl("^Slurm 命令", df$check)))
  for (nm in c("setsid", "nohup", "timeout", "bash")) {
    expect_equal(df$status[df$check == sprintf("本地原语 %s", nm)], "ok")
  }
  expect_equal(df$status[df$check == "本地 /proc"], "ok")
  expect_false(any(df$status == "fail"))
})

test_that("doctor(backend='slurm'): 本地原语项为 na; local 下缺 setsid 只 warn (可退化)", {
  dfs <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                    slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                    mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                    backend = "slurm", local_cmds = loc_cmds(), deps = character(0))
  expect_match(dfs$detail[dfs$check == "执行后端"], "Slurm 集群")
  # v1.13: Slurm 模式不展示本地原语行
  expect_false(any(grepl("^本地原语", dfs$check)))
  expect_false(any(grepl("本地 /proc", dfs$check)))
  expect_equal(dfs$group[dfs$check == "Slurm 命令 sbatch"], "Slurm 依赖")

  dfl <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                    slurm_cmds = character(0), sif_dirs = character(0),
                    mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                    backend = "local", local_cmds = loc_cmds(setsid = ""),
                    deps = character(0))
  expect_equal(dfl$status[dfl$check == "本地原语 setsid"], "warn")
  expect_match(dfl$detail[dfl$check == "本地原语 setsid"], "退化")
  expect_equal(dfl$status[dfl$check == "本地原语 nohup"], "ok")
})

test_that("doctor 默认按配置解析结果标注执行后端来源 (自动检测/配置指定)", {
  old <- diann.gui::cfg_get("EXEC_BACKEND_INFO")
  on.exit(diann.gui::set_core_const("EXEC_BACKEND_INFO", old), add = TRUE)
  diann.gui::set_core_const("EXEC_BACKEND_INFO",
                            list(request = "local", backend = "local", auto = FALSE))
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                   slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                   mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                   local_cmds = loc_cmds(), deps = character(0))
  expect_equal(df$status[df$check == "执行后端"], "ok")
  expect_match(df$detail[df$check == "执行后端"], "本地单机")
  expect_match(df$detail[df$check == "执行后端"], "配置指定")
})

# ---------- v1.13: 分组顺序 / group 列 / 汇总 / SIF 识别状态 / 只读 ----------

DOCTOR_GROUPS <- c("执行后端", "R 环境", "依赖包", "apptainer 依赖", "SIF 镜像",
                   "其他环境", "Slurm 依赖")

test_that("v1.13: 返回 df 含 group 列且按固定顺序分组; Slurm 组在最后", {
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                   slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                   mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                   backend = "slurm", deps = "shiny")
  expect_true(all(c("group", "check", "status", "detail") %in% names(df)))
  seen <- unique(df$group)
  expect_equal(seen, DOCTOR_GROUPS)                       # 顺序即分组顺序
  expect_equal(tail(seen, 1), "Slurm 依赖")               # Slurm 最后
  expect_equal(df$group[df$check == "执行后端"], "执行后端")
  expect_equal(df$group[df$check == "SIF 目录"], "SIF 镜像")
})

test_that("v1.13: 输出带组标题/符号/汇总行", {
  out <- capture.output(suppressMessages(
    df <- diann.gui::doctor(apptainer_cands = empty_cands(), partitions = character(0),
                            slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                            mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                            backend = "slurm", deps = character(0))))
  expect_true(any(grepl("^── \\[0\\] 执行后端 ──", out)))
  expect_true(any(grepl("^── \\[6\\] Slurm 依赖 ──", out)))
  expect_true(any(grepl("^[[:space:]]*[✓⚠✗–] ", out)))
  # 汇总行走 message (stderr), 单独捕获
  msg <- tryCatch(capture.output(
    type = "message",
    suppressWarnings(diann.gui::doctor(apptainer_cands = empty_cands(), partitions = character(0),
                                       slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                                       mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                                       backend = "slurm", deps = character(0)))),
    error = function(e) "")
  expect_true(any(grepl("^汇总: ✓ [0-9]+  ⚠ [0-9]+  ✗ [0-9]+  – [0-9]+ ", msg)))
})

test_that("v1.13: SIF 镜像组展示任意文件名与识别状态 (读缓存, 不跑容器)", {
  d <- tempfile("dosifid"); dir.create(d, showWarnings = FALSE)
  for (nm in c("image.sif", "diann-2.10.0.sif")) writeLines("x", file.path(d, nm))
  fi <- file.info(file.path(d, "diann-2.10.0.sif"))
  probe <- diann.gui:::sif_probe_record(list(entries = list(), version = 1L),
                                        file.path(d, "diann-2.10.0.sif"),
                                        unname(fi$size), as.numeric(fi$mtime),
                                        ver = "2.10.0", ok = TRUE, message = "ok")
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                   slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = d,
                   sif_probe = probe, mail_conf = "/nonexistent/mail.txt",
                   state_dir = tempdir(), backend = "slurm", deps = character(0))
  expect_match(df$detail[df$check == "SIF 镜像"], "2 个")                 # 任意文件名都计入
  id_row <- df$check == "SIF 版本识别"
  expect_true(any(id_row))
  expect_match(df$detail[id_row], "已识别 1/2")
})

test_that("v1.13: 本地模式含'本地作业状态文件'行 (只读), slurm 模式为 na", {
  dfl <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                    slurm_cmds = character(0), sif_dirs = character(0),
                    mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                    backend = "local", local_cmds = loc_cmds(), deps = character(0))
  expect_equal(dfl$group[dfl$check == "本地作业状态文件"], "其他环境")
  expect_equal(dfl$status[dfl$check == "本地作业状态文件"], "ok")          # 无文件 = ok

  dfs2 <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                     slurm_cmds = mk_fake_slurm("sbatch"), sif_dirs = character(0),
                     mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                     backend = "slurm", deps = character(0))
  expect_equal(dfs2$status[dfs2$check == "本地作业状态文件"], "na")
})

test_that("v1.13: doctor 只读 — 不创建/修改 SIF probe 与本地作业文件", {
  d <- tempfile("doro"); dir.create(d, showWarnings = FALSE)
  before <- list.files(tempdir(), all.files = TRUE)
  junk <- run_doctor(apptainer_cands = empty_cands(), partitions = character(0),
                     slurm_cmds = character(0), sif_dirs = character(0),
                     mail_conf = "/nonexistent/mail.txt", state_dir = d,
                     backend = "local", local_cmds = loc_cmds(), deps = character(0))
  after <- list.files(tempdir(), all.files = TRUE)
  expect_setequal(before, after)   # 不在 tempdir 留下 probe 文件等
})
