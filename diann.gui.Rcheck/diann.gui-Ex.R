pkgname <- "diann.gui"
source(file.path(R.home("share"), "R", "examples-header.R"))
options(warn = 1)
library('diann.gui')

base::assign(".oldSearch", base::search(), pos = 'CheckExEnv')
base::assign(".old_wd", base::getwd(), pos = 'CheckExEnv')
cleanEx()
nameEx("run_app")
### * run_app

flush(stderr()); flush(stdout())

### Name: run_app
### Title: 启动 DIA-NN GUI
### Aliases: run_app

### ** Examples

## Not run: run_app(port = 3838)



### * <FOOTER>
###
cleanEx()
options(digits = 7L)
base::cat("Time elapsed: ", proc.time() - base::get("ptime", pos = 'CheckExEnv'),"\n")
grDevices::dev.off()
###
### Local variables: ***
### mode: outline-minor ***
### outline-regexp: "\\(> \\)?### [*]+" ***
### End: ***
quit('no')
