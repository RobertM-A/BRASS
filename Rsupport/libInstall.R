instLib = commandArgs(T)[1]

r = getOption("repos") # hard code the UK repo for CRAN
r["CRAN"] = "http://cran.uk.r-project.org"
options(repos = r)
rm(r)
source("http://bioconductor.org/biocLite.R")

ipak <- function(pkg){
  new.pkg <- pkg[!(pkg %in% installed.packages()[, "Package"])]
  if (length(new.pkg))
    biocLite(new.pkg, ask=FALSE, lib=instLib, lib.loc=instLib)
  sapply(pkg, library, character.only = TRUE)
}

install.packages("devtools", lib=instLib)
library(devtools)
options(download.file.method = "auto")

ipak(c("data.table"))
ipak(c("gam"))

if ( version$major == 3 && version$minor < 2 ) {
  install.packages("VGAM_1.0-3.tar.gz", type="source", lib=instLib, lib.loc=instLib)
} else {
  ipak(c("VGAM"))
}

ipak(c("stringr"))
ipak(c("mgcv"))
ipak(c("poweRlaw"))
ipak(c("zlibbioc"))
ipak(c("RColorBrewer"))

install_github("sb43/copynumber", ref="f1688edc154f1a0e3aacf7781090afe02882f623")
