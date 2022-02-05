#!/usr/bin/Rscript

source("json_logging.R")
source("script_startup.R")

# These functions are defined in json_logging.R:
# setup_logging
# set_script_status
# format_utcnow
# arg_file_name
# log_file_name
# result_file_name
# log_event
# log_res
# log_error
# read_arg_file
# write_result_file
# write_start_file

# These functions are defined in script_startup.R:
# start_script

run_command <- function(args) {
  setup_logging(args)

  session_id <- args$session_id
  log_dir <- args$log_dir
  command_id <- args$command_id
  command_name <- args$command_name
  gen <- args$gen

  error <- ifelse(is.null(args$error), "none", args$error)
  started_at <- NULL
  running_at <- NULL
  write_start <- FALSE
  write_result <- FALSE

  jcat(paste0("run_command: error ", error))

  jcat("writing first log message")
  res <- create_command(args)
  futile.logger::flog.info(res$message)
  log_event("command_created", res)
  jcat("log file created")

  set_script_status("reading")
  arg_file <- arg_file_name(session_id, gen, command_id, command_name)
  arg_path <- file.path(log_dir, arg_file)
  if (identical(error, "reading")) {
    blowup_a()
  }

  res <- read_arg_file(arg_path)
  futile.logger::flog.info(res$message)
  jcat("read arg file")

  sleep_time <- 0.25
  num_lines <- res$args$num_lines
  for (line_no in 1:num_lines) {
    Sys.sleep(sleep_time)

    # read_arg_file can set status to "completed"
    if (!identical(res$status, "completed")) {
      res <- mock_status(command_id, line_no, num_lines, error)
    }

    status <- res$status
    message <- res$message
    result <- res$result
    errors <- res$errors
    res$result <- NULL
    res$errors <- list()

    if (is.null(started_at)) {
      started_at <- format_utcnow()
      res$started_at <- started_at
    }

    if (is.null(running_at) && status %in% c("running", "cancelled", "completed")) {
      running_at <- format_utcnow()
      res$running_at <- running_at
      write_start <- TRUE
    }

    if (status %in% c("cancelled", "completed")) {
      result_file <- result_file_name(session_id, gen, command_id, command_name)
      if (identical(status, "completed") && length(errors) == 0) {
        result_info <- list(
          succeeded = TRUE,
          file = result_file,
          errors = make_error_list(errors)
        )
      } else {
        result_info <- list(
          succeeded = FALSE,
          file = result_file,
          errors = make_error_list(errors)
        )
      }
      res$completed_at <- format_utcnow()
      res$result <- result_info
      write_result <- TRUE
    }

    if (write_start) {
      start_file <- start_file_name(session_id, gen, command_id, command_name)
      write_start_file(start_file, res)
      jcat("wrote start")
      write_start <- FALSE
      sleep_time <- 0.25
    }

    if (write_result && !is.null(result_file)) {
      write_result_file(result_file, res, result)
      jcat("wrote result")
    }

    log_res(message, res)
    jcat(paste0("wrote line ", line_no))

    if (write_result) {
      if (identical(error, "forever")) {
        jcat("running forever...")
        while (1) {
          Sys.sleep(sleep_time)
        }
      } else {
        break
      }
    } else {
      Sys.sleep(sleep_time)
    }
  }

  jcat("closing log file")
}

blowup_a <- function() {
  blowup_b()
}

blowup_b <- function() {
  blowup()
}

blowup <- function() {
  stop("kaboom")
}

create_command <- function(args) {
  res <- list(
    session_id = args$session_id,
    log_dir = args$log_dir,
    command_id = args$command_id,
    command_name = args$command_name,
    gen = args$gen,
    status = "created",
    message = paste0("Command ", args$command_id, " created")
  )

  set_script_status("created")

  res
}

mock_status <- function(command_id, line_no, num_lines, error) {
  raise_error <- FALSE
  progress_counter <- NULL
  progress_total <- NULL
  result <- NULL
  errors <- list()
  if (line_no == 1) {
    status <- "started"
    if (identical(error, "started")) {
      raise_error <- TRUE
    }
  } else if (line_no == 2) {
    status <- "validating"
    if (identical(error, "validating")) {
      raise_error <- TRUE
    }
  } else if (line_no < num_lines) {
    status <- "running"
    progress_counter <- line_no - 2
    progress_total <- num_lines - 3
    if (line_no == 4) {
      if (identical(error, "running")) {
        raise_error <- TRUE
      }
    }
  } else {
    status <- "completed"
    result <- list(params = list(list(a = 2), list(b = line_no)))
  }
  set_script_status(status)

  if (!is.null(progress_counter) && !is.null(progress_total)) {
    progress <- list(
      progress_counter = progress_counter,
      progress_total = progress_total,
      progress_phase = paste0("Compiling answers")
    )
  } else {
    progress <- NULL
  }

  res <- list(
    status = status,
    message = paste0("Command ", command_id, " ", status, " on line ", line_no),
    progress = progress,
    result = result,
    errors = errors
  )

  if (raise_error) {
    blowup_a()
  }

  res
}

# Execution starts here

args <- try_capture_stack(start_script())
if (inherits(args, "condition")) {
  # If there is an error, class(args) <- c("simpleError", "error", "condition")
  log_error(args, NULL)
} else {
  res <- try_capture_stack(run_command(args))
  # If there is an error, class(res) <- c("simpleError", "error", "condition")
  if (inherits(res, "condition")) {
    log_error(res, args)
  } else {
    res
  }
}