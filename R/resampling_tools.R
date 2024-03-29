# reduce 'training' indices to the length they would have
# if cvinst were cross validation on the fraction-sized task.
# training sets of rbn.reduceCrossval with small fraction
# are subsets of rbn.reduceCrossval with larger fraction
# when the given task and cvinst is the same.
# @param cvinst [CVDesc]
# @param task [Task]
# @param fraction [numeric(1)]
# @return [ResampleDesc]
rbn.reduceCrossval <- function(cvinst, task, fraction) {
  assertClass(cvinst, "ResampleInstance")
  assertClass(cvinst$desc, "CVDesc")
  assertTRUE(cvinst$desc$iters == length(cvinst$train.inds))
  assertTRUE(cvinst$desc$iters == length(cvinst$test.inds))

  set.seed(2)

  targetcol <- getTaskTargets(task)

  new.size <- max(round(getTaskSize(task) * fraction), cvinst$desc$iters)
  new.size.iters <- viapply(split(seq_len(new.size),
    rep_len(seq_len(cvinst$desc$iters),
      new.size)), length)

  if (cvinst$desc$stratify) {

    classfractions <- table(targetcol) / length(targetcol)

    cum.itertable <- classfractions * 0
    drop.per.iter <- lapply(seq_len(cvinst$desc$iters), function(iter) {
      # build "itertable"
      needed <- sum(new.size.iters[seq_len(iter)])  # how many entries do we want in this iteration?
      itertable.offset <- classfractions * 0  # rounding down itertable sometimes gives us 0; in that case we add an offset of 1
      repeat {
        # how many are still needed additionally to the ones in offset?
        needed.after.offset <- needed - sum(itertable.offset)
        if (needed.after.offset <= 0) {
          # if we have more in 'itertable.offset' than we want in this iteration, we just take 1 of each class.
          itertable[TRUE] <- 1
          needed <- sum(itertable)
          break
        }

        itertable.dbl <- classfractions * needed.after.offset + itertable.offset
        itertable <- floor(itertable.dbl)
        if (any(itertable == 0)) {
          itertable.offset[itertable == 0] = 1
        } else {
          break
        }
      }

      missing <- needed - sum(itertable)
      assertTRUE(missing >= 0 && missing <= length(itertable))
      rest <- itertable.dbl - itertable
      to.inc <- order(rest, decreasing = TRUE)[seq_len(missing)]
      itertable[to.inc] <- itertable[to.inc] + 1
      assertTRUE(sum(itertable) == needed)
      itertable <- itertable - cum.itertable
      cum.itertable <<- cum.itertable + itertable
      # "itertable" is now a 'table' that gives the desired number of instances for each class

      foldindices <- cvinst$test.inds[[iter]]
      foldindices.split <- split(foldindices, targetcol[foldindices])

      present.itertable <- sapply(foldindices.split, length)

      assertTRUE(all(names(present.itertable) == names(itertable)))

      drop.per.class <- lapply(names(itertable), function(class) {
        todrop <- max(present.itertable[class] - itertable[class], 0)

        curfi <- foldindices.split[[class]]
        droppropose <- order(runif(length(curfi)))  # want to treat the seed the same independent of 'fraction' value

        curfi[droppropose[seq_len(todrop)]]
      })
      unlist(drop.per.class)
    })

  } else {

    drop.per.iter <- lapply(seq_len(cvinst$desc$iters), function(iter) {
      needed <- new.size.iters[iter]
      curfi <- cvinst$test.inds[[iter]]
      todrop <- length(curfi) - needed
      assertTRUE(todrop >= 0)

      droppropose <- order(runif(length(curfi)))

      curfi[droppropose[seq_len(todrop)]]
    })

  }

  drop.all <- unlist(drop.per.iter)
  for (iter in seq_len(cvinst$desc$iters)) {
    dropping <- intersect(cvinst$train.inds[[iter]], drop.all)
    cvinst$train.inds[[iter]] <- setdiff(cvinst$train.inds[[iter]], drop.all)
    cvinst$test.inds[[iter]] <- c(cvinst$test.inds[[iter]], dropping)
    assertTRUE(!anyDuplicated(cvinst$test.inds[[iter]]))
  }
  cvinst$desc$id <- sprintf("%s%% reduced cross-validation", fraction * 100)
  class(cvinst$desc) <- "ResampleDesc"
  cvinst
}

# creates a union of resampling instances
#
# The union performs all train/test iterations from
# each `cvinst` member in a row. If predictions are saved,
# the measures can be evaluated when resulting predictions
# are split using `rbn.splitResamplingResult`.
#
# WORKS ONLY WITH `predict = "test"` RESAMPLING INSTANCES
#
# @param cvinst [list of ResampleInstance]
# @return [ResampleInstance]
rbn.unionResample <- function(cvinsts) {

  cvinsts <- unname(cvinsts)

  assertList(cvinsts, types = "ResampleInstance", min.len = 1, any.missing = FALSE)

  assertTRUE(length(unique(extractSubList(cvinsts, "size"))) == 1)

  groups <- unlist(lapply(seq_along(cvinsts), function(idx) {
    ci <- cvinsts[[idx]]
    if (!length(ci$group)) {
      ci$group <- factor(rep("1", length(ci$train.inds)))
    }
    assertCharacter(levels(ci$group), min.len  = 1)
    levels(ci$group) <- paste0(idx, "_", levels(ci$group))
    ci$group
  }))

  descs <- sapply(cvinsts, function(ci) {
    ci$desc[c("predict", "fixed", "iters", "stratify")]
  }, simplify = TRUE)

  assertTRUE(all(vlapply(descs["predict", , drop = FALSE], function(x) x == "test")))

  newdesc <- structure(list(
      fixed = all(vlapply(descs["fixed", , drop = FALSE], identity)),
      id = "resampling-union",
      iters = sum(viapply(descs["iters", , drop = FALSE], identity)),
      predict = "test",
      stratify = all(vlapply(descs["stratify", , drop = FALSE], identity))),
    class = c("UnionResampleDesc", "ResampleDesc"))

  newdesc$subsets <- unlist(lapply(cvinsts, function(ci) {
    di <- ci$desc
    if (inherits(di, "UnionResampleDesc")) {
      di$subsets
    } else {
      x <- di$iters
      names(x) <- di$id
      x
    }
  }))

  structure(list(
      desc = newdesc,
      size = cvinsts[[1]]$size,
      train.inds = unlist(extractSubList(cvinsts, "train.inds", simplify = FALSE), recursive = FALSE),
      test.inds = unlist(extractSubList(cvinsts, "test.inds", simplify = FALSE), recursive = FALSE),
      group = groups),
    class = "ResampleInstance")
}

# split the resampling result that was generated using a resampling
# instance that was `rbn.unionResample`'d
#
# Resulting ResampleResults will not have $aggr set, instead the
# performance needs to be re-calculated. Otherwise behaviour is the
# same as if resample() was called for individual ResamplingInstances.
#
# @param resampling.result [ResampleResult] ResampleResult
# @return [list of ResampleResult] the split up RRs
rbn.splitResamplingResult <- function(resampling.result) {
  assertClass(resampling.result, "ResampleResult")
  rdesc <- resampling.result$pred$instance$desc
  assertClass(rdesc, "ResampleDesc")
  if (!inherits(rdesc, "UnionResampleDesc")) {
    return(list(resampling.result))
  }
  subset.cum.idx <- 0L
  lapply(seq_along(rdesc$subsets), function(riidx) {
    riname <- names(rdesc$subsets)[riidx]
    subsetlen <- rdesc$subsets[riidx]
    subset.indices <- seq_len(subsetlen) + subset.cum.idx
    newrr <- resampling.result  # not necessary in a lapply, but avoids confusion
    newrr$measures.train <- newrr$measures.train[subset.indices, , drop = FALSE]
    newrr$measures.test <- newrr$measures.test[subset.indices, , drop = FALSE]
    newrr$aggr <- newrr$aggr * NA
    pred <- newrr$pred
    inst <- pred$instance
    desc <- inst$desc
    desc$id <- riname
    desc$iters <- subsetlen
    desc$subsets <- NULL
    class(desc) <- "ResampleDesc"
    inst$desc <- desc
    inst$train.inds <- inst$train.inds[subset.indices]
    inst$test.inds <- inst$test.inds[subset.indices]
    pred$instance <- inst
    pred$data <- pred$data[pred$data$iter %in% subset.indices, , drop = FALSE]
    pred$data$iter <- pred$data$iter - subset.cum.idx
    for (i in seq_len(subsetlen)) {
      assertSetEqual(pred$data$id[pred$data$iter == i], inst$test.inds[[i]])
    }
    pred$time <- pred$time[subset.indices]
    newrr$pred <- pred
    newrr$err.msgs <- newrr$err.msgs[subset.indices, , drop = FALSE]
    newrr$err.dumps <- newrr$err.dumps[subset.indices]
    newrr$extract <- newrr$extract[subset.indices]
    newrr$runtime <- NA

    subset.cum.idx <<- subset.cum.idx + subsetlen
    newrr
  })
}
