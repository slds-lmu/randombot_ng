#' Create a learner that writes to the `watchfile` to request a timeout
#' @param learner [Learner] the learner to wrap
#' @param timeouts [numeric] timeout in seconds. A vector of numbers > 0, minimum length 1.
#'   It gives the timeout for each resampling iteration. For the first resampling
#'   iteration (or an evaluation outside of \code{resample}), \code{timeouts[1]} seconds.
#'   If \code{timeouts} is shorter than the number of resampling iterations performed, then
#'   the last element of \code{timeouts} counts for the last few resampling iterations.
#'   E.g. if \code{timeouts} is \code{c(10, 20, 30)}, then for 5-fold cross validation, the
#'   timeouts are 10, 20, 30, 30, 30. It is usually sensible to have more generous timeout
#'   for later iterations.
#' @param kill.on.error [logical(1)] kill R process if writing the watchfile fails
#' @export
makeWatchedLearner <- function(learner, timeouts, kill.on.error = FALSE) {
  learner <- checkLearner(learner)
  assertNumeric(timeouts, lower = 0, finite = TRUE, any.missing = FALSE, min.len = 1)
  assertFlag(kill.on.error)
  learner$timeouts <- timeouts
  learner$kill.on.error <- kill.on.error
  class(learner) <- c("WatchedLearner", class(learner))
  learner
}


WATCHDOGPID <- NULL
rbn.setWatchdogTimeout <- function(timeout, msg = "") {
  if (!is.null(WATCHDOGPID)) {
    system(sprintf("kill %s", WATCHDOGPID))
  }
  usedtimeout <- as.numeric(timeout)
  if (length(usedtimeout) != 1 ||
      !is.finite(usedtimeout) ||
      !is.numeric(usedtimeout) ||
      usedtimeout < 0) {
    stopf("Invalid timeout %s", timeout)
  }
  loops <- trunc(usedtimeout / 10)
  resttimeout <- usedtimeout - 10 * loops  # not brave enough to use %% here
  stopifnot(resttimeout >= 0)

  WATCHDOGPID <<- system(
    sprintf(
        "(for ((i=0;i<%s;i++)) do sleep 10 ; if ! kill -0 $PPID 2>/dev/null ; then exit 0 ; fi ; done ; sleep %s ; echo \"KILLING $PPID WAU WAU ('%s')\" >&2 ; kill $PPID ; sleep 0.5 ; kill -9 $PPID ) > /dev/null & echo $!",
        loops, resttimeout, msg),
    intern = TRUE)
}

trainLearner.WatchedLearner <- function(.learner, ...) {
  tryCatch({
    iter <- inferResamplingIter()
    iter <- min(iter, length(.learner$timeouts))
    assertInt(iter, lower = 1)  # debug check
    timeout <- .learner$timeouts[iter]
    rbn.setWatchdogTimeout(timeout, msg = sprintf("iter: %s, t/o: %s", iter, timeout))
  }, error = function(e) { # if the timeout can't be written we commit sudoku
    cat("Error setting watch timeout!\n")
    if (.learner$kill.on.error) {
      cat("Killing.\n")
      quit(status = 254)
    }
  })
  NextMethod("trainLearner", .learner)
}

# Try to find out which resampling iteration we are in
inferResamplingIter <- function() {
  callnames <- sapply(sys.calls(), function(x) if (is.symbol(x[[1]])) as.character(x[[1]]) else "")
  resampling.index <- max(grep("calculateResampleIterationResult", callnames, fixed = TRUE), -1)
  if (resampling.index == -1) {
    return(1)
  }
  sys.frame(resampling.index)$i %??% 1
}
