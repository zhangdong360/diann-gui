# parse_diann_command: 命令导入解析器
test_that("diann 可执行名后才是参数区 (路径含空格也能定位)", {
  r <- parse_diann_command("/opt/my tools/diann-linux --matrices --qvalue 0.01")
  expect_true("--matrices" %in% r$bool)
  expect_equal(r$num[["--qvalue"]], 0.01)
})

test_that("布尔/数值/文本旗标与未知旗标分拣", {
  r <- parse_diann_command("diann --matrices --reanalyse --qvalue 0.005 --cut 'K*,R*,!*P' --loc-factor 40")
  expect_setequal(r$bool, c("--matrices", "--reanalyse"))
  expect_equal(r$num[["--qvalue"]], 0.005)
  expect_equal(r$text[["--cut"]], "K*,R*,!*P")
  expect_true("--loc-factor 40" %in% r$unknown)  # 未知旗标连值一起进 unknown
})

test_that("文件类旗标归类, --out 推导输出目录与报告名", {
  r <- parse_diann_command("diann --f '/d/a.raw' --f '/d/b.raw' --fasta '/d/h.fa' --lib '/d/l.parquet' --ref '/d/r.speclib' --temp '/t' --out '/o/myrep.tsv'")
  expect_equal(r$files$raws, c("/d/a.raw", "/d/b.raw"))
  expect_equal(r$files$fastas, "/d/h.fa")
  expect_equal(r$files$lib, "/d/l.parquet")
  expect_equal(r$files$ref, "/d/r.speclib")
  expect_equal(r$files$temp, "/t")
  expect_equal(r$files$out_dir, "/o")
  expect_equal(r$report_name, "myrep")
})

test_that("Windows 路径被拒收并记录", {
  r <- parse_diann_command("diann.exe --f C:\\data\\a.raw --lib I:\\lib.parquet --matrices")
  expect_length(r$files$raws, 0)
  expect_equal(r$files$lib, "")   # 标量字段初始为 "", Windows 值不覆盖
  expect_true(length(r$windows_paths) == 2)
  expect_true("--matrices" %in% r$bool)
})

test_that("修饰行解析为 名称/质量/位点 三元组", {
  r <- parse_diann_command("diann --var-mod 'UniMod:35,15.994915,M' --fixed-mod 'UniMod:4,57.021464,N'")
  expect_equal(r$var_mods[[1]], c("UniMod:35", "15.994915", "M"))
  expect_equal(r$fixed_mods[[1]], c("UniMod:4", "57.021464", "N"))
})

test_that("反斜杠续行合并, 注释行跳过", {
  r <- parse_diann_command("# 注释\ndiann --matrices \\\n  --qvalue 0.01")
  expect_true("--matrices" %in% r$bool)
  expect_equal(r$num[["--qvalue"]], 0.01)
})

test_that("粘贴命令含内置污染物库时转为 cont_fasta 开关", {
  set_core_const("CON_FASTA", "/shared/cRAP.fasta")
  on.exit(set_core_const("CON_FASTA", ""), add = TRUE)
  r <- parse_diann_command("diann --fasta '/shared/cRAP.fasta' --fasta '/d/h.fa' --matrices")
  expect_true(r$cont_fasta)
  expect_equal(r$files$fastas, "/d/h.fa")
})

test_that("空输入返回空结果骨架", {
  r <- parse_diann_command("   \n  ")
  expect_length(r$bool, 0)
  expect_length(r$num, 0)
  expect_length(r$files$raws, 0)
})

test_that("裸路径旗标 (Windows GUI 路径留空导出) 只记录不进 unknown", {
  r <- parse_diann_command("diann --lib --f '/d/a.raw' --out --qvalue 0.01 --matrices")
  expect_length(r$unknown, 0)
  expect_setequal(r$bare, c("--lib", "--out"))
  expect_true(r$bare_lib)
  # 有 RAW 文件: --lib 只是留空的谱库输入位, 不推断生成预测库
  expect_false("--gen-spec-lib" %in% r$bool)
  expect_true("--matrices" %in% r$bool)
})

test_that("裸 --lib + 无 RAW = 预测库生成意图, 推断 --gen-spec-lib", {
  r <- parse_diann_command("diann.exe --lib --threads 32 --out --fasta /d/h.fa --predictor --fasta-search")
  expect_true("--gen-spec-lib" %in% r$bool)
  expect_setequal(r$bare, c("--lib", "--out"))
  expect_length(r$unknown, 0)
})

test_that("--dir / --dir-all 解析为 RAW 目录 (不再是未知旗标)", {
  r <- parse_diann_command("diann --dir-all /d/raws --lib /d/l.parquet --matrices")
  expect_equal(r$files$raw_dir, "/d/raws")
  expect_length(r$files$raws, 0)
  expect_length(r$unknown, 0)
  r2 <- parse_diann_command("diann --dir /d/raws2 --qvalue 0.01")
  expect_equal(r2$files$raw_dir, "/d/raws2")
  expect_length(r2$unknown, 0)
  # 裸 --dir-all 与其它路径旗标一样被识别为"缺取值", 不进 unknown
  r3 <- parse_diann_command("diann --matrices --dir-all")
  expect_true("--dir-all" %in% r3$bare)
  expect_length(r3$unknown, 0)
})

test_that("命令末尾收尾的裸旗标同样不进 unknown", {
  r <- parse_diann_command("diann --f /d/a.raw --matrices --out")
  expect_length(r$unknown, 0)
  expect_true("--out" %in% r$bare)
  expect_false("--gen-spec-lib" %in% r$bool)
})

test_that("预览 Slurm 脚本: rc=$? 行截断, 旧格式尾部裸 --out 不再吞值; SBATCH -o 回填输出目录", {
  # 旧格式预览脚本尾部 "--lib --out" 曾把下一行 rc=$? 吞成 --out 取值,
  # 使主报告文件名变成 "rc=$?"、输出目录变成 "."
  tx <- paste(
    "#SBATCH -o '/share/o/slurm-%j.out'",
    "apptainer exec x diann-linux --fasta /share/h.fa --predictor --gen-spec-lib --out-lib /share/o/library.speclib --lib --out",
    "rc=$?",
    "printf '%s' \"$rc\" > 'diann_gui_preview.rc'",
    "exit $rc", sep = "\n")
  r <- parse_diann_command(tx)
  expect_equal(r$report_name, "")
  expect_equal(r$files$out_dir, "/share/o")
  expect_true("--gen-spec-lib" %in% r$bool)
  expect_setequal(r$bare, c("--lib", "--out"))
  expect_length(r$unknown, 0)
})

