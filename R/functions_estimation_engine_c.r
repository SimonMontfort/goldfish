########################
#
# Goldfish package
# Internal estimation routine
#
########################

# Estimation
estimate_c_int <- function(statsList,
                           nodes, nodes2,
                           defaultNetworkName,
                           modelTypeCall = c(
                             "DyNAM-MM", "DyNAM-M", "REM-ordered",
                             "DyNAM-M-Rate", "REM", "DyNAM-M-Rate-ordered"
                           ),
                           initialParameters = NULL,
                           fixedParameters = NULL,
                           excludeParameters = NULL,
                           initialDamping = 1,
                           maxIterations = 20,
                           dampingIncreaseFactor = 2,
                           dampingDecreaseFactor = 3,
                           maxScoreStopCriterion = 0.001,
                           # additional return objects
                           returnEventProbabilities = FALSE,
                           # additional parameter for DyNAM-MM
                           allowReflexive = FALSE,
                           isTwoMode = FALSE,
                           # additional parameter for DyNAM-M-Rate
                           addInterceptEffect = FALSE,
                           returnIntervalLogL = FALSE,
                           parallelize = FALSE,
                           cpus = 6,
                           verbose = FALSE,
                           silent = FALSE,
                           ignoreRepParameter = ignoreRepParameter,
                           testing = FALSE,
                           get_data_matrix = FALSE,
                           impute = FALSE,
                           engine = "default_c") {
  minDampingFactor <- initialDamping
  # CHANGED MARION
  # nParams: number of effects + 1 (if has intercept)
  nParams <- dim(statsList$initialStats)[3] - length(excludeParameters) + addInterceptEffect
  #
  parameters <- initialParameters
  if (is.null(initialParameters)) parameters <- rep(0, nParams)
  # deal with fixedParameters
  idUnfixedCompnents <- seq_len(nParams)
  idFixedCompnents <- NULL
  likelihoodOnly <- FALSE
  if (!is.null(fixedParameters)) {
    if (length(fixedParameters) != nParams) {
      stop("The length of fixedParameters is inconsistent with the length of the parameters, which is ",
           nParams, ".", call. = FALSE)
    }
    if (all(!is.na(fixedParameters))) likelihoodOnly <- TRUE
    parameters[!is.na(fixedParameters)] <- fixedParameters[!is.na(fixedParameters)]
    idUnfixedCompnents <- which(is.na(fixedParameters))
    idFixedCompnents <- which(!is.na(fixedParameters))
  }
  modelTypeCall <- match.arg(modelTypeCall)
  # modelTypeCall <- modelType

  ## PARAMETER CHECKS

  if (length(parameters) != nParams) {
    stop(paste("Error in estimation. Wrong number of initial parameters passed to function:", length(parameters)))
  }
  if (!(length(minDampingFactor) %in% c(1, nParams))) {
    stop(paste("Error in estimation. minDampingFactor has wrong length:", length(minDampingFactor)))
  }
  if (dampingIncreaseFactor < 1 || dampingDecreaseFactor < 1) {
    stop(paste("Error in estimation. Damping increase / decrease factors cannot be smaller than one."))
  }

  ## REDUCE STATISTICS LIST

  if (verbose) cat("Reducing data\n")

  # CHANGED MARION: add colOnly and rowOnly in a smart way for the estimation
  reduceMatrixToVector <- F
  reduceArrayToMatrix <- F
  if (modelTypeCall %in% c("DyNAM-M-Rate", "DyNAM-M-Rate-ordered")) {
    reduceMatrixToVector <- T
  } else if (modelTypeCall == "DyNAM-M") {
    reduceArrayToMatrix <- T
  }

  # CHANGED MARION: updated function
  # for rate model with intercept, add a table of all 1 to the statsList$initStats
  statsList <- modifyStatisticsList(statsList, modelTypeCall,
    reduceMatrixToVector = reduceMatrixToVector,
    reduceArrayToMatrix = reduceArrayToMatrix,
    excludeParameters = excludeParameters,
    addInterceptEffect = addInterceptEffect
  )

  # CHANGED MARION: handle composition changes for counting average number of actors
  # and remove absent actors for each estimation step
  compChangeName1 <- attr(nodes, "events")["present" == attr(nodes, "dynamicAttribute")]
  compChangeName2 <- attr(nodes2, "events")["present" == attr(nodes2, "dynamicAttribute")]
  compChange1 <- NULL
  compChange2 <- NULL
  if (!is.null(compChangeName1) && length(compChangeName1) > 0) compChange1 <- get(compChangeName1)
  if (!is.null(compChangeName2) && length(compChangeName2) > 0) compChange2 <- get(compChangeName2)


  ## ADD INTERCEPT
  # CHANGED MARION
  # replace first parameter with an initial estimate of the intercept
  if ( (modelTypeCall == "REM" || modelTypeCall == "DyNAM-M-Rate") && addInterceptEffect) {
    totalTime <- sum(unlist(statsList$intervals), na.rm = TRUE) +
      sum(unlist(statsList$rightCensoredIntervals), na.rm = TRUE)
    nEvents <- length(statsList$orderEvents)
    # CHANGED MARION: remove the use of the events object
    time <- statsList$eventTime[[1]]
    previoustime <- time
    currentInterval <- 1
    currentRCInterval <- 1
    nAvgActors <- 0
    if (!is.null(nodes$present)) {
      nActors <- length(which(nodes$present == TRUE))
    } else {
      nActors <- dim(nodes)[1]
    }
    for (i in 1:nEvents) {
      previoustime <- time
      if (statsList$orderEvents[[i]] == 1) {
        time <- time + statsList$intervals[[currentInterval]]
        currentInterval <- currentInterval + 1
      } else {
        time <- time + statsList$rightCensoredIntervals[[currentRCInterval]]
        currentRCInterval <- currentRCInterval + 1
      }
      nplus <- intersect(
        intersect(which(compChange1$time > previoustime), which(compChange1$time <= time)),
        which(compChange1$replace == TRUE)
      )
      nminus <- intersect(
        intersect(which(compChange1$time > previoustime), which(compChange1$time <= time)),
        which(compChange1$replace == FALSE)
      )
      nActors <- nActors + length(nplus) - length(nminus)
      nAvgActors <- nAvgActors + nActors
    }
    nAvgActors <- nAvgActors / length(statsList$orderEvents)
    if (is.null(initialParameters) && (is.null(fixedParameters) || is.na(fixedParameters[1]))) {
      initialInterceptEstimate <- log(nEvents / totalTime / nAvgActors)
      parameters[1] <- initialInterceptEstimate
    }
  }
  #

  ## SET VARIABLES BASED ON STATSLIST

  # CHANGED MARION
  nEvents <- length(statsList$orderEvents) # number of events


  ## SET VARIABLES BASED ON STATSLIST
  twomode_or_reflexive <- (allowReflexive || isTwoMode)
  n_events <- length(statsList$orderEvents)
  n_parameters <- dim(statsList$initialStats)[3]
  n_actors1 <- dim(statsList$initialStats)[1]
  n_actors2 <- nActors <- dim(statsList$initialStats)[2]


  ## CONVERT UPDATES INTO THE FORMAT ACCEPTED BY C FUNCTIONS
  temp <- convert_change(statsList$dependentStatsChange)
  stat_mat_update <- temp$statMatUpdate
  stat_mat_update_pointer <- temp$statMatUpdatePointer
  if (addInterceptEffect) {
    stat_mat_update[3, ] <- stat_mat_update[3, ] + 1
  }
  # Convert the right-censored events
  # which will be a zero matrice and a zero vector if there's no right-censored event
  if (length(statsList$rightCensoredIntervals) == 0) {
    stat_mat_rightcensored_update <- matrix(0, 4, 1)
    stat_mat_rightcensored_update_pointer <- c(0)
  } else {
    temp <- convert_change(statsList$rightCensoredStatsChange)
    stat_mat_rightcensored_update <- temp$statMatUpdate
    stat_mat_rightcensored_update_pointer <- temp$statMatUpdatePointer
    if (addInterceptEffect) {
      stat_mat_rightcensored_update[3, ] <- stat_mat_rightcensored_update[3, ] + 1
    }
  }

  ## CONVERT COMPOSITION CHANGES INTO THE FORMAT ACCEPTED BY C FUNCTIONS
  compChangeName1 <- attr(nodes, "events")["present" == attr(nodes, "dynamicAttribute")]
  compChangeName2 <- attr(nodes2, "events")["present" == attr(nodes2, "dynamicAttribute")]
  if (!is.null(compChangeName1) && length(compChangeName1) > 0) {
    temp <- get(compChangeName1)
    temp <- sanitizeEvents(temp, nodes)
    temp <- C_convert_composition_change(temp, unlist(statsList$eventTime))
    presence1_update <- temp$presenceUpdate
    presence1_update_pointer <- temp$presenceUpdatePointer
  } else {
    presence1_update <- matrix(0, 0, 0)
    presence1_update_pointer <- c(0)
  }

  if (!is.null(compChangeName2) && length(compChangeName2) > 0) {
    temp <- get(compChangeName2)
    temp <- sanitizeEvents(temp, nodes2)
    temp <- C_convert_composition_change(temp, unlist(statsList$eventTime))
    presence2_update <- temp$presenceUpdate
    presence2_update_pointer <- temp$presenceUpdatePointer
  } else {
    presence2_update <- matrix(0, 0, 0)
    presence2_update_pointer <- c(0)
  }

  if (!is.null(nodes$present)) {
    presence1_init <- nodes$present
  } else {
    presence1_init <- rep(TRUE, length(nodes))
  }

  if (!is.null(nodes2$present)) {
    presence2_init <- nodes2$present
  } else {
    presence2_init <- rep(TRUE, length(nodes2))
  }

  ## CONVERT TYPES OF EVENTS AND TIMESPANS INTO THE FORMAT ACCEPTED BY C FUNCTIONS
  is_dependent <- (as.numeric(unlist(statsList$orderEvents)) == 1)
  timespan <- numeric(length(is_dependent))
  timespan[is_dependent] <- as.numeric(unlist(statsList$intervals))
  timespan[(!is_dependent)] <- as.numeric(unlist(statsList$rightCensoredIntervals))



  ## CONVERT INFOS OF SENDERS AND RECEIVERS INTO THE FORMAT ACCEPTED BY C FUNCTIONS
  event_mat <- t(matrix(c(unlist(statsList$eventSender), unlist(statsList$eventReceiver)), ncol = 2))

  ## CONVERT THE INITIALIZATION OF DATA MATRIX INTO THE FORMAT ACCEPTED BY C FUNCTIONS
  stat_mat_init <- matrix(0, n_actors1 * n_actors2, n_parameters)
  for (i in 1:n_parameters) {
    stat_mat_init[, i] <- t(statsList$initialStats[, , i])
  }


  ## ESTIMATION: INITIALIZATION

  if (verbose) cat(paste("Estimating model type with the super efficient new method", modelTypeCall, "\n"))

  iIteration <- 1
  informationMatrix <- matrix(0, nParams, nParams)
  score <- rep(0, nParams)
  logLikelihood <- 0
  isConverged <- FALSE
  isInitialEstimation <- T
  logLikelihood.old <- -Inf
  parameters.old <- initialParameters
  score.old <- NULL
  informationMatrix.old <- NULL


  ## GATHERING INFO IF WE USE THE GATHER-COMPUTE ENGINE.
  if (engine == "gather_compute") {
    gathered_data <- gather_(
      modelTypeCall = modelTypeCall,
      event_mat = event_mat,
      timespan = timespan,
      is_dependent = is_dependent,
      stat_mat_init = stat_mat_init,
      stat_mat_update = stat_mat_update,
      stat_mat_update_pointer = stat_mat_update_pointer,
      stat_mat_rightcensored_update = stat_mat_rightcensored_update,
      stat_mat_rightcensored_update_pointer = stat_mat_rightcensored_update_pointer,
      presence1_init = presence1_init,
      presence1_update = presence1_update,
      presence1_update_pointer = presence1_update_pointer,
      presence2_init = presence2_init,
      presence2_update = presence2_update,
      presence2_update_pointer = presence2_update_pointer,
      n_actors1 = n_actors1,
      n_actors2 = n_actors2,
      twomode_or_reflexive = twomode_or_reflexive,
      silent = silent, # If not silent, output the progress of data gathering
      impute = impute
    )
    size_gathered_data <- object.size(gathered_data)
  }



  while (TRUE) {
    ## CALCULATE THE LOGLIKELIHOOD, THE FISHER INFORMATION MATRIX, AND THE DERIVATIVE

    ## GATHER-COMPUTE ENGINE
    if (engine == "gather_compute") {
      res <- compute_(
        modelTypeCall = modelTypeCall,
        parameters = parameters,
        stat_all_events = gathered_data$stat_all_events,
        selected = gathered_data$selected,
        selected_actor1 = gathered_data$selected_actor1,
        selected_actor2 = gathered_data$selected_actor2,
        n_candidates = gathered_data$n_candidates,
        n_candidates1 = gathered_data$n_candidates1,
        n_candidates2 = gathered_data$n_candidates2,
        timespan = timespan,
        is_dependent = is_dependent,
        twomode_or_reflexive = twomode_or_reflexive
      )
    }

    ### DEFAULT_C ENGINE
    if (engine == "default_c") {
      res <- estimate_(
        modelTypeCall = modelTypeCall,
        parameters = parameters,
        event_mat = event_mat,
        timespan = timespan,
        is_dependent = is_dependent,
        stat_mat_init = stat_mat_init,
        stat_mat_update = stat_mat_update,
        stat_mat_update_pointer = stat_mat_update_pointer,
        presence1_init = presence1_init,
        presence1_update = presence1_update,
        presence1_update_pointer = presence1_update_pointer,
        stat_mat_rightcensored_update = stat_mat_rightcensored_update,
        stat_mat_rightcensored_update_pointer = stat_mat_rightcensored_update_pointer,
        presence2_init = presence2_init,
        presence2_update = presence2_update,
        presence2_update_pointer = presence2_update_pointer,
        n_actors1 = n_actors1,
        n_actors2 = n_actors2,
        twomode_or_reflexive = twomode_or_reflexive,
        impute = impute
      )
    }




    logLikelihood <- res$logLikelihood
    score <- as.numeric(res$derivative)
    informationMatrix <- res$fisher
    if (returnIntervalLogL) intervalLogL <- as.numeric(res$intervalLogL)

    # TODO add a possibility to return the whole probability matrix
    if (returnEventProbabilities) {
      eventProbabilities <- if (is.null(res$pMatrix)) {
        paste("not implemented for model type", modelTypeCall)
      } else {
        res$pMatrix
      }
    }

    if (isInitialEstimation && any(is.na(unlist(res))) && !all(parameters[-1] == 0)) {
      stop("Estimation not possible with initial parameters. Try using zeros instead.")
    }

    # If we only want the likelihood break here
    if (likelihoodOnly) {
      inverseInformationUnfixed <- matrix(0, nParams, nParams)
      score <- rep(0, nParams)
      isConverged <- TRUE
      break
    }

    # we don't consider the fixed components of the score. It's for the fixing parameter feature. \
    score[idFixedCompnents] <- 0

    if (!verbose && !silent) {
      cat(paste0(
        "\rMax score: ",
        round(max(abs(score)), round(-logb(maxScoreStopCriterion / 1, 10)) + 1),
        " (", iIteration, ").        "
      ))
    }
    if (verbose) {
      cat(paste("\n\nLikelihood:", logLikelihood, "in iteration", iIteration))
      cat(paste("\n_parameters:", toString(parameters)))
      cat(paste("\nScore:", toString(score)))
      # print(informationMatrix)
    }

    if (logLikelihood <= logLikelihood.old || any(is.na(unlist(res)))) {
      if (verbose) message("\nNo improvement in estimation. Resetting values and adjusting damping.")
      # reset values
      logLikelihood <- logLikelihood.old
      parameters <- parameters.old
      score <- score.old
      informationMatrix <- informationMatrix.old
      minDampingFactor <- minDampingFactor * dampingIncreaseFactor
    } else {
      logLikelihood.old <- logLikelihood
      parameters.old <- parameters
      score.old <- score
      informationMatrix.old <- informationMatrix
      minDampingFactor <- max(1, minDampingFactor / ifelse(isInitialEstimation, 1, dampingDecreaseFactor))
    }

    # end of initial estimation
    isInitialEstimation <- F

    # Calculate the UPDATE distance taking into account the DAMPING
    dampingFactor <- minDampingFactor

    # INVERT information matrix
    # We only invert the unfixed part of the parameter. The fixed components of the score have already be set to be 0.
    # It's for the fixing parameter feature.
    informationMatrixUnfixed <- informationMatrix[idUnfixedCompnents,idUnfixedCompnents]
    inverseInformationUnfixed <- try(solve(informationMatrixUnfixed), silent = TRUE)
    if (class(inverseInformationUnfixed) == "try-error") {
      stop("Matrix cannot be inverted; probably due to collinearity between parameters.")
    }

      update <- rep(0,nParams)
      update[idUnfixedCompnents] <- (inverseInformationUnfixed %*% score[idUnfixedCompnents]) / dampingFactor


    if (verbose) {
      cat(paste("\nUpdate: ", toString(update)))
      cat(paste("\nDamping factor:", toString(dampingFactor)))
    }

    # check for stop criteria
    if (max(abs(score)) <= maxScoreStopCriterion) {
      isConverged <- TRUE
      if (!silent) cat(paste("\nStopping as maximum absolute score is below", maxScoreStopCriterion, ".\n"))
      break
    }
    if (iIteration > maxIterations) {
      if (!silent) {
        message(paste(
          "\nStopping as maximum of", maxIterations,
          "iterations have been reached. No convergence.\n"
        ))
      }
      break
    }

    parameters <- parameters + update

    iIteration <- iIteration + 1
  } # end of while

  ## ESTIMATION: END
  # calculate standard errors
  # the variance for the fixed compenents should be 0
  stdErrors <- rep(0,nParams)
  stdErrors[idUnfixedCompnents] <- sqrt(diag(inverseInformationUnfixed))

  # define, type and return result
  estimationResult <- list(
    parameters = parameters,
    standard.errors = stdErrors,
    log.likelihood = logLikelihood,
    final.score = score,
    final.informationMatrix = informationMatrix,
    convergence = list(isConverged, max.abs.score = max(abs(score))),
    n.iterations = iIteration,
    n.events = nEvents,
    model.type = modelTypeCall
  )
  if (engine == "gather_compute") {
    estimationResult$size.intermediate <- size_gathered_data
    if (testing) estimationResult$intermediate <- gathered_data
  }
  if (testing) estimationResult$intermediate_data <- DataMatrixAndId$intermediate_data
  if (returnIntervalLogL) estimationResult$interval.logL <- intervalLogL
  if (returnEventProbabilities) estimationResult$event.probabilities <- eventProbabilities
  attr(estimationResult, "class") <- "result.goldfish"
  estimationResult
}



##############################################################################################
# different implementation for different modelTypeCall



## ESTIMATE FOR DIFFERENT MODELS
estimate_ <- function(modelTypeCall,
                      parameters,
                      event_mat,
                      timespan,
                      is_dependent,
                      stat_mat_init,
                      stat_mat_update,
                      stat_mat_update_pointer,
                      stat_mat_rightcensored_update,
                      stat_mat_rightcensored_update_pointer,
                      presence1_init,
                      presence1_update,
                      presence1_update_pointer,
                      presence2_init,
                      presence2_update,
                      presence2_update_pointer,
                      n_actors1,
                      n_actors2,
                      twomode_or_reflexive,
                      impute) {
  if (modelTypeCall == "DyNAM-MM") {
    res <- estimate_DyNAM_MM(
      parameters,
      event_mat,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      impute
    )
  }

  if (modelTypeCall == "DyNAM-M") {
    res <- estimate_DyNAM_choice(
      parameters,
      event_mat,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      impute
    )
  }

  if (modelTypeCall == "REM-ordered") {
    res <- estimate_REM_ordered(
      parameters,
      event_mat,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      impute
    )
  }

  if (modelTypeCall == "REM") {
    res <- estimate_REM(
      parameters,
      event_mat,
      timespan,
      is_dependent,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      stat_mat_rightcensored_update,
      stat_mat_rightcensored_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      impute
    )
  }

  if (modelTypeCall == "DyNAM-M-Rate") {
    res <- estimate_DyNAM_rate(
      parameters,
      event_mat,
      timespan,
      is_dependent,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      stat_mat_rightcensored_update,
      stat_mat_rightcensored_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      impute
    )
  }

  if (modelTypeCall == "DyNAM-M-Rate-ordered") {
    res <- estimate_DyNAM_rate_ordered(
      parameters,
      event_mat,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      impute
    )
  }
  return(res)
}






## GATHER FOR DIFFERENT MODELS
gather_ <- function(modelTypeCall,
                    event_mat,
                    timespan,
                    is_dependent,
                    stat_mat_init,
                    stat_mat_update,
                    stat_mat_update_pointer,
                    presence1_init,
                    presence1_update,
                    presence1_update_pointer,
                    stat_mat_rightcensored_update,
                    stat_mat_rightcensored_update_pointer,
                    presence2_init,
                    presence2_update,
                    presence2_update_pointer,
                    n_actors1,
                    n_actors2,
                    twomode_or_reflexive,
                    silent,
                    impute) {

  if (modelTypeCall == "REM-ordered" || modelTypeCall == "REM" || modelTypeCall == "REM" ||
      modelTypeCall == "DyNAM-MM") {
    # For DyNAM-MM, we deal with twomode_or_reflexive in the estimation for convenience.
    if (modelTypeCall == "DyNAM-MM") twomode_or_reflexive <- TRUE
    gathered_data <- gather_sender_receiver_model(
      event_mat,
      is_dependent,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      stat_mat_rightcensored_update,
      stat_mat_rightcensored_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      !silent, # verbose
      impute
    )
  }

  if (modelTypeCall == "DyNAM-M") {
    gathered_data <- gather_receiver_model(
      event_mat,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      !silent, # output the progress of data gathering
      impute
    )
  }


  if (modelTypeCall == "DyNAM-M-Rate-ordered" || modelTypeCall == "DyNAM-M-Rate") {
    gathered_data <- gather_sender_model(
      event_mat,
      is_dependent,
      stat_mat_init,
      stat_mat_update,
      stat_mat_update_pointer,
      stat_mat_rightcensored_update,
      stat_mat_rightcensored_update_pointer,
      presence1_init,
      presence1_update,
      presence1_update_pointer,
      presence2_init,
      presence2_update,
      presence2_update_pointer,
      n_actors1,
      n_actors2,
      twomode_or_reflexive,
      !silent, # verbose
      impute
    )
  }

  return(gathered_data)
}


## COMPUTE FOR DIFFERENT MODELS
compute_ <- function(modelTypeCall,
                     parameters,
                     stat_all_events,
                     selected,
                     selected_actor1,
                     selected_actor2,
                     n_candidates,
                     n_candidates1,
                     n_candidates2,
                     timespan,
                     is_dependent,
                     twomode_or_reflexive) {
  if (modelTypeCall == "DyNAM-M" || modelTypeCall == "REM-ordered" || modelTypeCall == "DyNAM-M-Rate-ordered") {
    res <- compute_multinomial_selection(
      parameters,
      stat_all_events,
      n_candidates,
      selected
    )
  }


  if (modelTypeCall == "DyNAM-M-Rate" || modelTypeCall == "REM") {
    res <- compute_poisson_selection(
      parameters,
      stat_all_events,
      n_candidates,
      selected,
      timespan,
      is_dependent
    )
  }

  if (modelTypeCall == "DyNAM-MM") {
    res <- compute_coordination_selection(
      parameters,
      stat_all_events,
      n_candidates,
      n_candidates1,
      n_candidates2,
      selected,
      selected_actor1,
      selected_actor2,
      twomode_or_reflexive
    )
  }

  return(res)
}
