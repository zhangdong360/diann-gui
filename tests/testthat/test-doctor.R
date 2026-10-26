# doctor(): 运行环境自检 (全部注入, 不依赖真实集群/包)

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
  d <- file.path(tempdir(), sprintf("dosif_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  writeLines("x", file.path(d, "diann-2.7.0.sif"))

  slurm <- c(sbatch = "/usr/bin/sbatch", squeue = "/usr/bin/squeue", sacct = "/usr/bin/sacct",
             sinfo = "/usr/bin/sinfo", scontrol = "/usr/bin/scontrol")
  cands <- data.frame(path = "/opt/ap/bin/apptainer", kind = "apptainer", source = "common",
                      version = "1.4.5", ok = TRUE, checked_at = 1, stringsAsFactors = FALSE)
  df <- run_doctor(apptainer_cands = cands, partitions = "compute", slurm_cmds = slurm,
                   sif_dirs = d, mail_conf = "/nonexistent/mail.txt", state_dir = tempdir(),
                   deps = character(0))

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
                   slurm_cmds = c(sbatch = "", squeue = "/usr/bin/squeue"),
                   sif_dirs = character(0), mail_conf = "/nonexistent/mail.txt",
                   state_dir = "/nonexistent/state/dir", deps = character(0))
  expect_equal(df$status[df$check == "Slurm 命令 sbatch"], "fail")
  expect_equal(df$status[df$check == "Slurm 命令 squeue"], "ok")
  expect_equal(df$status[df$check == "Slurm 分区"], "warn")
  expect_equal(df$status[df$check == "apptainer"], "warn")
  expect_equal(df$status[df$check == "状态目录"], "fail")
})

test_that("doctor 对过宽的邮件配置权限给出警告, 600 时为 ok", {
  d <- file.path(tempdir(), sprintf("domail_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(d, showWarnings = FALSE)
  mc <- file.path(d, "mail_config.txt")
  writeLines("smtp_host=x", mc)
  Sys.chmod(mc, "0644")
  df <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                   slurm_cmds = c(sbatch = "/usr/bin/sbatch"), sif_dirs = character(0),
                   mail_conf = mc, state_dir = tempdir(), deps = character(0))
  expect_equal(df$status[df$check == "邮件配置"], "warn")
  expect_match(df$detail[df$check == "邮件配置"], "600")

  Sys.chmod(mc, "0600")
  df2 <- run_doctor(apptainer_cands = empty_cands(), partitions = "compute",
                    slurm_cmds = c(sbatch = "/usr/bin/sbatch"), sif_dirs = character(0),
                    mail_conf = mc, state_dir = tempdir(), deps = character(0))
  expect_equal(df2$status[df2$check == "邮件配置"], "ok")
})
