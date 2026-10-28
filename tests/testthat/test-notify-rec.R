# 通知状态文件: 锁 + 原子写 + 记录字段 (临时 HOME, 不碰真实队列)
test_that("mkdir 锁互斥并可释放", {
  expect_true(notify_lock_acquire(timeout = 2))
  expect_false(notify_lock_acquire(timeout = 1))
  notify_lock_release()
  expect_true(notify_lock_acquire(timeout = 2))
  notify_lock_release()
})

test_that("diann_notify_add 补默认字段, save/load 往返一致", {
  unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
  set_core_const("MAIL_ENABLED", TRUE)  # 临时打开闸门 (add 只检查标志, 不真正发信)
  on.exit(set_core_const("MAIL_ENABLED", FALSE), add = TRUE)
  diann_notify_add(list(jobid = "101", to = "a@b.c", task = "T", out_dir = "/o",
                        out_file = "/o/report.tsv", sif = "/x.sif",
                        script_path = "/o/s.sh", desc_file = ""))
  st <- diann_notify_load()
  expect_length(st$recs, 1)
  r <- st$recs[[1]]
  expect_identical(as.character(r$jobid), "101")
  expect_false(r$done)
  expect_equal(r$attempts, 0L)
  expect_true(nzchar(r$submitted))
  # 新记录插最前
  diann_notify_add(list(jobid = "102", to = "a@b.c", task = "T2", out_dir = "/o",
                        out_file = "/o/report.tsv", sif = "/x.sif",
                        script_path = "/o/s2.sh", desc_file = ""))
  st2 <- diann_notify_load()
  expect_equal(as.character(st2$recs[[1]]$jobid), "102")
  unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
})

test_that("损坏的状态文件安全回退为空", {
  writeLines("not an rds", NOTIFY_STATE)
  st <- diann_notify_load()
  expect_equal(length(st$recs), 0)
  unlink(NOTIFY_STATE, force = TRUE)
})

test_that("notify_defer_unknown: 未知状态在 3 轮内延后发送, 之后才退化", {
  st <- list(label = "未知")
  expect_true(notify_defer_unknown(st, 0))
  expect_true(notify_defer_unknown(st, 2))
  expect_false(notify_defer_unknown(st, 3))
  expect_false(notify_defer_unknown(list(label = "成功"), 0))
  expect_false(notify_defer_unknown(NULL, 0))
})

test_that("watcher_spawn_command: 显式带用户库路径与配置文件", {
  cmd <- watcher_spawn_command(state = "/tmp/s.rds", pidfile = "/tmp/s.pid",
                               logf = "/tmp/s.log", cfg_file = "/tmp/c.R")
  expect_match(cmd, "DIANN_GUI_CONFIG='/tmp/c.R'", fixed = TRUE)
  expect_match(cmd, ".libPaths(c(", fixed = TRUE)
  expect_match(cmd, "watch_daemon", fixed = TRUE)
  expect_match(cmd, "--no-save --slave", fixed = TRUE)
  expect_match(cmd, "< /dev/null &", fixed = TRUE)
  cmd2 <- watcher_spawn_command(state = "/tmp/s.rds", pidfile = "/tmp/s.pid",
                                logf = "/tmp/s.log", cfg_file = "")
  expect_false(grepl("DIANN_GUI_CONFIG", cmd2, fixed = TRUE))
})

# ---------- v1.12: snapshot 注入 + local 记录不调 sacct/squeue ----------

test_that("diann_notify_tick(snapshot=): local 记录按 rc/产物合成成功并发送邮件, 全程不调 Slurm 命令", {
  unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
  old_enabled <- diann.gui::cfg_get("MAIL_ENABLED")
  old_python <- diann.gui::cfg_get("MAIL_PYTHON")
  old_path <- Sys.getenv("PATH")
  on.exit({
    diann.gui::set_core_const("MAIL_ENABLED", old_enabled)
    diann.gui::set_core_const("MAIL_PYTHON", old_python)
    Sys.setenv(PATH = old_path)
    unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
  }, add = TRUE)

  td <- file.path(tempdir(), sprintf("notify_local_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  sd <- file.path(td, "diann_gui_scripts"); dir.create(sd, showWarnings = FALSE)
  jid <- "1000301"
  sp <- file.path(sd, "diann_local.sh"); writeLines("#!/bin/bash", sp)
  writeLines("0", sub("\\.sh$", ".rc", sp))
  rep_ok <- file.path(td, "report.tsv"); writeLines(c("h", "r"), rep_ok)
  now <- as.integer(Sys.time())
  lf <- file.path(td, sprintf("local-%s.out", jid))
  writeLines(c(sprintf("DIANN_GUI_START_EPOCH %d", now - 20), "exit code: 0",
               sprintf("DIANN_GUI_END_EPOCH %d", now)), lf)

  # 假 Slurm 命令: 一旦被调用就落 marker (证明 local 记录没走 squeue/sacct)
  bind <- file.path(td, "bin"); dir.create(bind)
  marker <- file.path(td, "slurm_called.txt")
  for (nm in c("squeue", "sacct", "sbatch", "scancel")) {
    writeLines(c("#!/bin/bash", sprintf("echo %s >> %s", nm, shQuote(marker)), "exit 1"),
               file.path(bind, nm))
    Sys.chmod(file.path(bind, nm), "0755")
  }
  mail_log <- file.path(td, "mail_args.txt")
  mail_sh <- file.path(td, "fake_mail.sh")
  writeLines(c("#!/bin/bash", sprintf("printf '%%s\\n' \"$@\" > %s", shQuote(mail_log)),
               "exit 0"), mail_sh)
  Sys.chmod(mail_sh, "0755")

  Sys.setenv(PATH = paste(bind, old_path, sep = ":"))
  diann.gui::set_core_const("MAIL_ENABLED", TRUE)
  diann.gui::set_core_const("MAIL_PYTHON", mail_sh)
  expect_true(diann_notify_add(list(jobid = jid, to = "a@b.c", task = "L", out_dir = td,
                                    out_file = rep_ok, sif = "/x.sif", script_path = sp,
                                    desc_file = "", backend = "local", log_out = lf)))

  # 作业仍在队列里 (snapshot 注入) -> 本轮跳过, 不发信
  expect_false(isTRUE(diann_notify_tick(snapshot = list(squeue_map = list("1000301" = "RUNNING")))))
  expect_false(isTRUE(diann_notify_load()$recs[[1]]$done))
  expect_false(file.exists(mail_log))

  # 队列空 -> 四层合成 (rc=0 + 新产物) = 成功, 发信并置 done
  expect_true(isTRUE(diann_notify_tick(snapshot = list(squeue_map = list()))))
  st <- diann_notify_load()$recs[[1]]
  expect_true(isTRUE(st$done))
  expect_equal(st$status_label, "成功")
  expect_equal(st$rc, 0L)
  expect_true(file.exists(mail_log))
  args <- readLines(mail_log, warn = FALSE)
  expect_true("--job-id" %in% args)
  expect_true(jid %in% args)
  expect_true("--status-label" %in% args)
  expect_true("成功" %in% args)
  expect_true("--rc" %in% args)
  # local 记录全程没有调用 Slurm 命令
  expect_false(file.exists(marker))
})

test_that("diann_notify_tick: 旧 slurm 记录 (无 backend 字段) 仍按 slurm 解释且 snapshot 生效", {
  unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
  old_enabled <- diann.gui::cfg_get("MAIL_ENABLED")
  old_python <- diann.gui::cfg_get("MAIL_PYTHON")
  on.exit({
    diann.gui::set_core_const("MAIL_ENABLED", old_enabled)
    diann.gui::set_core_const("MAIL_PYTHON", old_python)
    unlink(c(NOTIFY_STATE, paste0(NOTIFY_STATE, ".lock")), recursive = TRUE, force = TRUE)
  }, add = TRUE)
  td <- file.path(tempdir(), sprintf("notify_slurm_%d_%d", Sys.getpid(), as.integer(runif(1, 1, 1e9))))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  mail_log <- file.path(td, "mail_args.txt")
  mail_sh <- file.path(td, "fake_mail.sh")
  writeLines(c("#!/bin/bash", sprintf("printf '%%s\\n' \"$@\" >> %s", shQuote(mail_log)),
               "exit 0"), mail_sh)
  Sys.chmod(mail_sh, "0755")
  diann.gui::set_core_const("MAIL_ENABLED", TRUE)
  diann.gui::set_core_const("MAIL_PYTHON", mail_sh)
  diann_notify_add(list(jobid = "424242", to = "a@b.c", task = "S", out_dir = td,
                        out_file = file.path(td, "r.tsv"), sif = "/x.sif",
                        script_path = file.path(td, "s.sh"), desc_file = ""))
  # 无 backend 字段 -> diann_notify_add 按当前后端补; snapshot 注入避免真实 squeue/sacct
  expect_false(isTRUE(diann_notify_tick(snapshot = list(squeue_map = list("424242" = "RUNNING")))))
  st <- diann_notify_load()$recs[[1]]
  expect_false(isTRUE(st$done))
  expect_true(nzchar(as.character(st$backend)))
})

# ---------- v1.14.1: mail_gate_info 门控三态 (WSL2 缺 python3 盲区) ----------

test_that("mail_gate_info: 缺配置/缺 python3/齐备 三态与可操作提示", {
  old <- list(conf = diann.gui::cfg_get("MAIL_CONF"),
              py = diann.gui::cfg_get("MAIL_PYTHON"),
              en = diann.gui::cfg_get("MAIL_ENABLED"))
  on.exit({
    diann.gui::set_core_const("MAIL_CONF", old$conf)
    diann.gui::set_core_const("MAIL_PYTHON", old$py)
    diann.gui::set_core_const("MAIL_ENABLED", old$en)
  }, add = TRUE)
  td <- file.path(tempdir(), sprintf("mailgate_%d", Sys.getpid()))
  dir.create(td, showWarnings = FALSE, recursive = TRUE)
  conf <- file.path(td, "mail_config.txt")

  # ① 配置缺失 (WSL2 新装最常见): enabled=FALSE, 提示给示例复制命令
  diann.gui::set_core_const("MAIL_CONF", conf)
  diann.gui::set_core_const("MAIL_PYTHON", "/usr/bin/python3")
  diann.gui::set_core_const("MAIL_ENABLED", FALSE)
  g <- mail_gate_info()
  expect_false(g$enabled)
  expect_false(g$has_conf)
  expect_true(g$has_python)
  expect_match(g$reason, conf, fixed = TRUE)
  expect_match(g$hint, "file.copy(", fixed = TRUE)
  expect_match(g$hint, "mail_config.example.txt", fixed = TRUE)

  # ② 配置在但缺 python3 (v1.14 前的盲区: 只查文件存在会漏报)
  writeLines("smtp_host=x", conf)
  diann.gui::set_core_const("MAIL_PYTHON", "")
  diann.gui::set_core_const("MAIL_ENABLED", FALSE)
  g2 <- mail_gate_info()
  expect_false(g2$enabled)
  expect_true(g2$has_conf)
  expect_false(g2$has_python)
  expect_match(g2$reason, "python3", fixed = TRUE)
  expect_match(g2$hint, "apt install python3", fixed = TRUE)

  # ③ 三要素齐备 (文件 + python + MAIL_ENABLED): enabled=TRUE 且无提示文案
  diann.gui::set_core_const("MAIL_PYTHON", "/usr/bin/python3")
  diann.gui::set_core_const("MAIL_ENABLED", TRUE)
  g3 <- mail_gate_info()
  expect_true(g3$enabled)
  expect_equal(g3$reason, "")
  expect_equal(g3$hint, "")
  expect_equal(g3$conf_path, conf)

  unlink(td, recursive = TRUE, force = TRUE)
})
