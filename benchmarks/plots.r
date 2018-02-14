#
# call: Rscript ../plots.r 2018-02-03_053826
# (curr. workdir is where the run-???.csv is)
#
# packages to install: dplyr, ggplot2, svglite, gplots, anytime, gridExtra
# (e.g. install.packages('svglite'))
#

# if run in RStudio one can select the csv in a file dialogue
INTERACTIVE <- FALSE

library(dplyr)
library(ggplot2)
library(gplots)
library(anytime)
library(grid)
library(gridExtra)

if (INTERACTIVE) {
  #library('ggedit')    # only if interactive editing
  fnames <- file.choose()
  fname <- fnames[1]
  RUN <- sub('.*run-([-_0-9]+).csv', '\\1', fname)
  bp <- dirname(fname)
  fname2 <- paste(bp, '/report_', RUN, '.txt', sep='')
  fname3 <- paste(bp, '/bench-settings', sep='')
  fname4 <- paste(bp, '/times.csv', sep='')
} else {
  args = commandArgs(trailingOnly=TRUE)
  RUN <- args[1]
  fname <- paste('run-', RUN, '.csv', sep='')
  fname2 <- paste('report_', RUN, '.txt', sep='')
  fname3 <- 'bench-settings'
  fname4 <- 'times.csv'
}

DESC=''                    # Add custom text to titles
k <- 6                     # Protocol parameters determining
SLOTLENGTH <- 20           # the length of an epoch
EPOCHLENGTH <- 10*k*SLOTLENGTH

# have trx times?
hasTrxTimes <- FALSE
if (file.exists(fname4)) {
  hasTrxTimes <- TRUE
}

# names of relay nodes
relays <- c('r-a-1', 'r-a-2', 'r-a-3'
          , 'r-b-1', 'r-b-2'
          , 'r-c-1', 'r-c-2'
          , 'u-a-1', 'u-b-1', 'u-c-1'
            )

# names of unprivileged relay nodes
uRelays <- c('u-a-1', 'u-b-1', 'u-c-1')

# read in transaction times
if (hasTrxTimes) {
  times <- read.csv(fname4, header=FALSE, col.names=c("time", "cumm"))
}

# prep and read in benchmark parameters
system(paste("sed -e 's/, /\\\n/g' ", fname3, " > ", fname3, "2", sep=''))
params <- read.csv(paste(fname3, "2", sep=''), header=FALSE, 
                   col.names = c("parameter","value"), sep="=",
                   stringsAsFactor=FALSE)

maxparam <- length(params[,2])
if (params[maxparam,1]=="systemstart") {
  params[maxparam+1,1] <- "time UTC"
  params[maxparam+1,2] <- paste("", anytime(as.numeric(params[maxparam,2]), tz="UTC"), sep='')
}

# read the report of the benchmark run
readReport <- function(filename, run=RUN) {
  print(paste('reading data from', filename, sep=' '))
  report <- read.table(filename, sep=':', nrows=3, skip=1, col.names = c("desc", "count"))
  return (report);
}

# read and pre-process data from a benchmark run
readData <- function(filename, run=RUN) {
    #filename <- paste('run-', run, '.csv', sep='')
    print(paste('reading data from', filename, sep=' '))
    data <- read.csv(filename)
    t0 = min(data$time)
    # time after start of experiment, in seconds
    data$t <- (data$time - t0) %/% 1e6
    data$clustersize <- as.factor(data$clustersize)
    data$concF <- as.factor(data$conc)
    data$delayF <- as.factor(data$delay)
    data <- data[!(data$txType %in% c('failed')),]
    data$endT <- ave(data$t, data$run, FUN=max)
    data$isRelay <- data$node %in% relays
    data$isRelay <- as.factor(data$isRelay)
    levels(data$isRelay) <- c('Core Nodes', 'Relay Nodes')

    # make the labels shorter
    levels(data$txType)[levels(data$txType)=="mp_ProcessTransaction_Modify"] <- "hold tx"
    levels(data$txType)[levels(data$txType)=="mp_ProcessTransaction_Wait"] <- "wait tx"
    levels(data$txType)[levels(data$txType)=="mp_ApplyBlock_Modify"] <- "hold block"
    levels(data$txType)[levels(data$txType)=="mp_ApplyBlock_Wait"] <- "wait block"
    levels(data$txType)[levels(data$txType)=="mp_ApplyBlockWithRollback_Modify"] <- "hold rollback"
    levels(data$txType)[levels(data$txType)=="mp_ApplyBlockWithRollback_Wait"] <- "wait rollback"
    levels(data$txType)[levels(data$txType)=="mp_ApplyBlock_SizeAfter"] <- "size after block"
    levels(data$txType)[levels(data$txType)=="mp_ApplyBlockWithRollback_SizeAfter"] <- "size after rollback"
    levels(data$txType)[levels(data$txType)=="mp_ProcessTransaction_SizeAfter"] <- "size after tx"

    return(data)
}

# dashed vertical lines at the epoch boundaries
epochs <- function(d) {
    epochs <- data.frame(start=seq(from=0, to=max(d$t), by=EPOCHLENGTH))
    geom_vline(data=epochs,
               aes(xintercept = start, alpha=0.65)
             , colour='red'
             , linetype='dashed'
               )
    }

# dotted vertical lines every k slots
kslots <- function(d) {
    kslots <- data.frame(start=seq(from=0, to=max(d$t), by=k*SLOTLENGTH))
    geom_vline(data=kslots,
               aes(xintercept = start, alpha=0.40)
             , colour='red'
             , linetype='dotted'
               )
    }

# histograms the rate of sent and written transactions
histTxs <- function(d, run=RUN, desc=DESC) {
  dd <- d %>%
    filter(txType %in% c("submitted", "written"))
  maxtx <- max(dd$txCount)
  crit <- "submitted"
  dd <- d %>%
    filter(txType %in% c(crit))
#  ggplot(dd, aes(txCount)) + stat_ecdf(geom="step") +
#      ggtitle(paste(crit, 'transactions', desc, sep = ' ')) +
#      ylab("") + xlab(paste("tx", crit, sep=" "))

#  qqplot(x=1:length(dd$txCount), y=dd$txCount, xlab="", ylab="tx/slot", main=paste(crit, 'transactions', desc, sep = ' '))

  hist(dd$txCount, main=paste('transaction count per slot', desc, sep = ' ')
       , breaks=seq(0,maxtx, by=1)
       , col=gray.colors(maxtx/2)
       , xlab = crit )
  crit <- "written"
  dd <- d %>%
    filter(txType %in% c(crit))
#  ggplot(dd, aes(txCount)) + stat_ecdf(geom="step") +
#      ggtitle(paste(crit, 'transactions', desc, sep = ' ')) +
#      ylab("") + xlab(paste("tx", crit, sep=" "))

#  qqplot(x=1:length(dd$txCount), y=dd$txCount, xlab="", ylab="tx/slot", main=paste(crit, 'transactions', desc, sep = ' '))

  hist(dd$txCount, main=paste('transaction count per slot', desc, sep = ' ')
       , breaks=seq(0,maxtx, by=1)
       , col=gray.colors(maxtx/2)
       , xlab = crit )
}

# plot the rate of sent and written transactions
plotTxs <- function(d, run=RUN, desc=DESC) {
    dd <- d %>%
        filter(txType %in% c("submitted", "written"))
    ggplot(dd, aes(t, txCount/slotDuration)) +
        geom_point(aes(colour=node)) +
        geom_smooth() +
        ggtitle(paste(
            'Transaction frequency for core and relay nodes, run at '
          , run, desc, sep = ' ')) +
        xlab("t [s]") +
        ylab("transaction rate [Hz]") +
        facet_grid(txType ~ run) +
        epochs(d) + kslots(d) +
        guides(size = "none", colour = "legend", alpha = "none")
    }

# plot the mempool residency for core and relay nodes
plotMempools <- function(d, str='core and relay', run=RUN, desc=DESC) {
    dd <- d %>%
        filter(txType %in% c("size after block"
                           , "size after rollback"
                           , "size after tx"))
    ggplot(dd, aes(t, txCount)) +
        geom_point(aes(colour=node)) +
        ggtitle(paste(
            'Mempool sizes for', str, 'nodes, run at '
          , run, desc, sep = ' ')) +
        xlab("t [s]") +
        ylab("Mempool size [# of transactions]") +
        facet_grid(txType ~ isRelay, scales= "free", space = "free") +
        epochs(d) +
        guides(size = "none", colour = "legend", alpha = "none")
}

# plot the wait and hold times for the local state lock
plotTimes <- function(d, str='core and relay', run=RUN, desc=DESC) {
    dd <- d %>%
            filter(txType %in% c("hold tx"
                               , "wait tx"
                               , "hold block"
                               , "wait block"
                               , "hold rollback"
                               , "wait rollback"
                                 ))
        #dd$t <- dd$t %/% 1000
    ggplot(dd, aes(t, txCount)) +
        geom_point(aes(colour=node)) +
        ggtitle(paste(
            'Wait and work times for', str, 'nodes, run at '
          , run, desc, sep = ' ')) +
        xlab("t [s]") +
        ylab("Times waiting for/holding the lock [microseconds]") +
        scale_y_log10() +
        facet_grid(txType ~ isRelay) +
        epochs(d) +
        guides(size = "none", colour = "legend", alpha = "none")
}

plotOverview <- function(d, report, run=RUN, desc=DESC) {
  def.par <- par(no.readonly = TRUE)
  layout(mat = matrix(c(1,1,1,1,2,3,4,4,5,5,6,6), 3, 4, byrow = TRUE), heights=c(2,3,4))
  
  textplot(paste("\nBenchmark of ", run), cex = 2, valign = "top")
  bp <- barplot(as.matrix(report[,2]), col=c("green", "blue", "red"))
  textplot(report, show.rownames = FALSE)
  textplot(params, show.rownames = FALSE)
  
  histTxs(data)

  par(def.par)
  #layout(matrix(c(1,1), 1, 1, byrow = TRUE))
}

plotDuration <- function(run=RUN, desc=DESC) {

  formatylabels <- function(x) { lab <- sprintf("%1.2f", x) }

  # 1
  t1 <- grid.text(paste("\nTransaction times ", run), draw = FALSE)
  # 2
  bxstats <- boxplot.stats(times$time)
  t2 <- grid.text(paste("median time", sprintf("%1.1f", bxstats$stats[3]), "seconds", sep=" "), draw = FALSE)
  # 3
  g1 <- ggplot(times, aes(x=time, y=cumm)) +
          geom_point(col="blue") +
          geom_vline(xintercept = bxstats$stats, col=c("grey","grey60","darkgreen","grey60","grey")) +
          xlab("time (s)") + ylab("") +
          scale_y_continuous(label=formatylabels)
  # 4
  g2 <- ggplot(times, aes(y=time, x=1)) +
          geom_boxplot(fill = "lightblue", outlier.color = "darkred", outlier.size = 3, outlier.shape = 6) +
          coord_flip() +
          xlab("") + ylab("") +
          scale_x_continuous(label=formatylabels) +
          theme(axis.text.y = element_text(color="white"), axis.ticks.y = element_blank())

  grid.arrange(t1, t2, g1, g2, ncol = 1, heights = c(1,0.5,4,1))
}

# plotDuration0 <- function(run=RUN, desc=DESC) {
#   def.par <- par(no.readonly = TRUE)
#   layout(mat = matrix(c(1,1,1,0,2,0,0,3,0), 3, 3, byrow = TRUE), widths = c(1,3,1), heights = c(3,6,2))
#   par(mar=c(3,1,2,1))
#   
#   # 1
#   textplot(paste("\nTransaction times ", run), cex = 1.4, valign = "top")
#   # 2
#   qqplot(times$time, times$cumm, main="transaction times", ylab="", xlab="seconds")
#   # 3
#   boxplot(times$time, main="", horizontal = TRUE, col="lightblue", boxwex=0.35)
#   
#   par(def.par)
# }

report <- readReport(fname2)
data <- readData(fname)

png(filename=paste('overview-', RUN, '.png', sep=''))
plotOverview(data, report)
dev.off()
plotOverview(data, report)

if (hasTrxTimes) {
  png(filename=paste('duration-', RUN, '.png', sep=''))
  plotDuration()
  dev.off()
  plotDuration()
}

plotTxs(data)
ggsave(paste('txs-', RUN, '.svg', sep=''))
ggsave(paste('txs-', RUN, '.png', sep=''))

plotMempools(data)
ggsave(paste('mempools-', RUN, '.svg', sep=''))
ggsave(paste('mempools-', RUN, '.png', sep=''))

plotTimes(data)
ggsave(paste('times-', RUN, '.svg', sep=''))
ggsave(paste('times-', RUN, '.png', sep=''))

#observe only core nodes:
plotMempools(data %>% filter(!(node %in% relays)), 'core')

#observe only unprivileged relays:
plotMempools(data %>% filter(node %in% uRelays), 'unprivileged relay')

#observe only privileged relays:
plotMempools(data %>% filter((node %in% relays) & (!(node %in% uRelays))), 'privileged relay')

plotTimes(data %>% filter(!(node %in% relays)), 'core')
