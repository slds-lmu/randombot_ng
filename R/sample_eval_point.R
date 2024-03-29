
# @param learner.name [character(1)]: name of learner, as it is found in paramtbl
# @param learner.object [Learner]: actual learner object. Could be gotten from
#   rbn.getLearner, but we don't waste time with that
# @param data [Task] The dataset. Used to check paramtbl 'condition's
# @param paramtbl [data.frame] parameter table generated with rbn.compileParamTbl
# @return [character] a single string per eval point that can be parsed with
#   `rbn.parseEvalPoint()`. Is of the form `list(<param.name>=c(<param.values>),...)`.
#   It is possible that zero, one, or two strings are returned.
rbn.sampleEvalPoint <- function(learner.object, data, seed, paramtbl) {
  learner.name <- learner.object$id
  assertChoice(learner.name, paramtbl$learner)

  task.p <- getTaskNFeats(data)
  task.n <- getTaskSize(data)

  paramtbl <- paramtbl[learner.name == paramtbl$learner, , drop = FALSE]

  ps.orig <- getLearnerParamSet(learner.object)

  superrate <- rbn.getSetting("SUPERRATE")
  assertNumeric(superrate, len = 1, lower = 0, upper = 1, any.missing = FALSE)

  strafo <- rbn.getSetting("SAMPLING_TRAFO")
  assertString(strafo)
  defaulttrafo <- function(values, morevalues, trafo, lower, upper, is.int) {
      values <- values * (upper - lower + as.numeric(is.int && is.null(trafo))) + lower
      if (!is.null(trafo)) {
        values <- vnapply(values, trafo)
        if (is.int) {
          values <- assertIntegerish(values, coerce = TRUE)
        }
      } else if (is.int) {
        values <- as.integer(floor(values))
      }
      values
  }
  normtrafo <- function(values, morevalues, trafo, lower, upper, is.int) {
    values <- qnorm(values, mean = (upper + lower) / 2, sd = (upper - lower) / 2)
    if (!is.null(trafo)) {
      if (is.int) {
        values <- vnapply(values, function(x) {
          tryCatch(assertIntegerish(trafo(x), coerce = TRUE),
            error = function(e) NA)
        })
      } else {
        values <- vnapply(values, function(x) {
          tryCatch(trafo(x), error = function(e) NA)
        })
      }
    } else if (is.int) {
      values <- as.integer(floor(values))
    }
    values
  }
  if (grepl("^partnorm\\([^)]*\\)$", strafo)) {
    proportion <- eval(parse(text = strafo), envir = list(partnorm=base::c))
    assertNumber(proportion, lower = 0, upper = 1)
    strafo <- "partnorm"
  }
  trafofun <- switch(strafo,
    none = function(values, morevalues, trafo, lower, upper, is.int) {
      if (is.null(trafo)) trafo <- identity
      lower <- trafo(lower)
      upper <- trafo(upper) + as.numeric(is.int)
      values <- values * (upper - lower) + lower
      if (is.int) {
        values <- as.integer(floor(values))
      }
      values
    },
    default = defaulttrafo,
    norm = normtrafo,
    partnorm = function(values, morevalues, trafo, lower, upper, is.int) {
      ifelse(morevalues >= proportion,
        defaulttrafo(values, morevalues, trafo, lower, upper, is.int),
        normtrafo(values, morevalues, trafo, lower, upper, is.int)
      )
    },
    stop("bad SAMPLING_TRAFO setting"))

  condition.violated <- FALSE

  vals <- lapply(seq_len(nrow(paramtbl)), function(entry) {
    if (condition.violated) {
      return(NULL)
    }
    param.given <- lapply(paramtbl, `[[`, entry)
    param.name <- param.given$parameter
    param.lrn <- ps.orig$pars[[param.name]]
    len <- rbn.getParamLengthOrOne(param.lrn)

    hashseed <- strtoi(paste0("0x", substr(digest(c(learner.name, param.name), algo = "md5"), 1, 7)))
    set.seed(hashseed + seed)


    randval <- runif(len)
    randmoreval <- runif(len)

    if (isNumeric(param.lrn) && !is.na(param.given$lower)) {
      assert(!is.na(param.given$upper))
      assert(length(param.given$values) == 0)
      cnt <- 0
      repeat {
        val <- trafofun(randval, randmoreval, param.given$trafo, param.given$lower, param.given$upper, isInteger(param.lrn))
        if (!any(is.na(val)) && isFeasible(param.lrn, val)) {
          break
        }
        randval <- runif(len)
        randmoreval <- runif(len)
        cnt <- cnt + 1
        if (cnt > 1e5) {
          stopf("Giving up on parameter %s", param.name)
        }
      }
      # be extra cautious with the 'format' call
      val <- format(val, trim = TRUE, digits = 6, scientific = TRUE,
        nsmall = 0, justify = "none", width = 0, big.mark = "",
        small.mark = "", decimal.mark = ".", drop0trailing = FALSE)
      trueval <- eval(parse(text = val))
    } else {
      assert(is.na(param.given$lower) && is.na(param.given$upper))
      if (isLogical(param.lrn) && !length(param.given$values)) {
        param.given$values = c("FALSE", "TRUE")
      }
      assert(length(param.given$values) > 0)
      choice <- floor(randval * length(param.given$values)) + 1
      val <- param.given$values[choice]
      if (isVector(param.lrn)) {
        trueval <- getValues(param.lrn)[val]
        if (isLogical(param.lrn)) {
          trueval <- unlist(trueval, recursive = FALSE, use.names = FALSE)
        }
      } else {
        trueval <- getValues(param.lrn)[[val]]
      }

      if (isDiscrete(param.lrn)) {
        val = paste0('"', val, '"')
      }
    }
    if (length(val) != 1) {
      val <- sprintf("c(%s)", collapse(val, ","))
    }
    # check condition
    if (!param.given$condition(trueval, n = task.n, p = task.p)) {
      condition.violated <<- TRUE
      return(NULL)
    }
    val
  })

  if (condition.violated) {
    return(character(0))
  }

  # filter out by requirements
  # This is a bit tedious, but we are not taking chances: build string, parse string, delete values that don't
  # fulfill requirements, build the string again
  names(vals) <- paramtbl$parameter
  wholestring <- paste(names(vals), vals, sep = "=", collapse = ",")
  parsed <- rbn.parseEvalPoint(paste0("list(", wholestring, ")"), learner.object, multiple = FALSE)
  assertSetEqual(names(parsed), names(vals))
  delendum <- Filter(function(param.name) {
    requires.given <- paramtbl$requires[[which(param.name == paramtbl$parameter)]]
    !is.null(requires.given) &&
      !isTRUE(eval(requires.given, envir = parsed, enclos = .GlobalEnv))
  }, names(parsed))
  vals <- vals[names(vals) %nin% delendum]
  wholestring <- paste(names(vals), vals, sep = "=", collapse = ",")

  set.seed(seed)
  if (runif(1) < superrate) {
    supertail <- c(FALSE, TRUE)
  } else {
    supertail <- FALSE
  }
  paste0("list(", wholestring, ",SUPEREVAL=", supertail, ")")
}

# compile parameter table (turn strings into expressions etc.)
# @param table [data.frame | character(1)] either a data.table, or a file name that
#   can be read with read.csv
# @param ... additional arguments to read.csv if `table` is a [character(1)].
rbn.compileParamTbl <- function(table, ...) {
  required.names <- c("learner", "parameter", "values", "lower", "upper", "trafo",
    "requires", "condition")

  assert(
      checkDataFrame(table),
      checkString(table)
  )

  if (testString(table)) {
    table <- read.csv(table, ...)
    assertDataFrame(table)
  }
  assertNames(colnames(table), permutation.of = required.names)
  table <- table[required.names]

  table$learner <- as.character(table$learner)  # learner name, as in rbn.getLearner

  table$parameter <- as.character(table$parameter) # parameter name

  table$values <- as.character(table$values)  # if discrete: list of value names
  table$values[is.na(table$values)] <- ""
  table$values <- gsub("^\\s+|\\s+$", "", table$values)
  table$values <- strsplit(table$values, ",\\s*")

  table$lower <- as.numeric(table$lower)
  table$upper <- as.numeric(table$upper)

  table$trafo <- lapply(as.character(table$trafo), function(x) {
    if (!is.na(x) && !grepl("^\\s*$", x)) {
      eval(parse(text = sprintf("function(x) { %s }", x)), envir = .GlobalEnv)
    }
  })

  table$requires <- lapply(as.character(table$requires), function(x) {
    if (!is.na(x) && !grepl("^\\s*$", x)) {
      asQuoted(x)
    }
  })

  table$condition <- lapply(as.character(table$condition), function(x) {
    if (!is.na(x) && !grepl("^\\s*$", x)) {
      eval(parse(text = sprintf("function(x, n, p) { %s }", x)), envir = .GlobalEnv)
    } else {
      function(x, n, p) TRUE
    }
  })
  table
}
