library(jsonlite, quietly = TRUE)
library(argparser, quietly = TRUE)

source("json_logging.R")

stop_if_empty <- function(x, item) {
  if (!(length(x) == 1 && nzchar(x))) {
    stop(paste0("missing argument ", item))
  }
}

#' Startup procedure for Rscript- or littler-based API
#'
#' \code{start_script} Loads libraries, parses command line arguments,
#' and sets up R session options used by the logging system.
#'
#' @return A named list with these components:
#'  \code{log_dir} The directory for argument and log files on the file system.
#'  \code{session_id} The session ID.
#'  \code{command_id} The command (command) ID.
#'  \code{command_name} The command name.
#'  \code{gen} The generation number when the command is started.
#'  \code{error} A non-empty string naming a phase if the command is to raise an
#'      error (testing flag).
start_script <- function() {
  # Used for logging--save important data in R options
  # digits.secs for millisecond time formats
  context <- list(
    digits.secs = 3,
    daptics_script_pid = Sys.getpid(),
    daptics_script_status = "initializing"
  )
  options(context)

  # From here on out, we might expect errors
  load_required_libraries()

  # Create a parser
  p <- argparser::arg_parser("daptics rscript")

  # Add command line arguments. If not specified, missing args default to NA.
  p <- argparser::add_argument(p, "--log-dir", "directory containing log file", short = "-p")
  p <- argparser::add_argument(p, "--session-id", "session id", short = "-s")
  p <- argparser::add_argument(p, "--command-id", "command id", short = "-i")
  p <- argparser::add_argument(p, "--command-name", "command name", short = "-n")
  p <- argparser::add_argument(p, "--gen", "gen", short = "-g", type = "integer")
  p <- argparser::add_argument(p, "--error", "phase in which to generate error result", short = "-e", default = "none")

  # Rscript function
  pa <- script_path_and_argv()

  # Change to directory of script
  setwd(dirname(pa$script))

  # Parse the command line arguments
  args <- argparser::parse_args(p, argv = pa$argv)
  if (identical(args$error, "initializing")) {
    stop("arg-blowup")
  } else {
    jcat("parsed script args")
  }

  stop_if_empty(args$log_dir, "log_dir")
  stop_if_empty(args$session_id, "session_id")
  stop_if_empty(args$command_id, "command_id")
  stop_if_empty(args$command_name, "command_name")
  valid_names <- c("create", "update", "generate", "analytics")
  if (!(args$command_name %in% valid_names)) {
    stop("invalid argument -n/--command-name (choose from 'create', 'update', 'generate', 'analytics')")
  }
  stop_if_empty(args$gen, "gen")

  # Save session and command data in R options
  context <- list(
    daptics_script_name = basename(pa$script),
    daptics_log_dir = args$log_dir,
    daptics_session_id = args$session_id,
    daptics_command_id = args$command_id,
    daptics_command_name = args$command_name,
    daptics_command_gen = args$gen
  )
  options(context)

  args
}

#' Parse command line arguments from \code{Rscript} or \code{littler}.
#'
#' \code(script_path_and_argv) accepts command line arguments from
#' either \code{Rscript} or \code{littler} runtimes, parses the "--file="
#' argument, and returns that value, along with any "trailing" arguments.
#'
#' @return A named list with \code{script} and \code{argv} components.
script_path_and_argv <- function() {
  # With littler, argv is already parsed, and should be a character vector like:
  # [1] "--file=/home/pzingg/..."
  # [2] "-s"
  # [3] "S2kkby1jg77bdma700ct"
  # [4] "-c"
  # [5] "C2kkby2mm0c9vnm682gq"
  littler <- exists("argv", env = globalenv())

  # With Rscript, commandArgs returns a vector like this:
  # [1] "/usr/lib/R/bin/exec/R"
  # [2] "--slave"
  # [3] "--no-restore"
  # [4] "--file=/home/pzingg/..."
  # [5] "--args"
  # [6] "-s"
  # [7] "S2kkmshsqwmkhhfb16fk"
  # [8] "-c"
  # [9] "C2kkmsjs57a10jvzx855"
  if (!littler) {
    argv <- commandArgs(trailingOnly = FALSE)
  }

  # Find the path to our file
  m <- grepl("--file=(.+)", argv)
  if (!any(m)) {
    # When using littler, you must supply "--file=script_path" as an explicit argument
    # Rscript does this automatically
    if (littler) {
      stop("r invocation requires explicit --file=<path.to.script> command line argument.")
    } else {
      stop("Rscript error, no implicit --file=<path.to.script> command line argument found.")
    }
  }

  # Get full path from "--file=xxx" argument
  script_path <- gsub("--file=(.+)", "\\1", argv[m])
  script_path <- normalizePath(script_path)

  # Now remove all but "trailing" args
  if (littler) {
    # Remove --file arg from argv list
    args <- argv[!m]
    if (is.null(args)) args <- character()
  } else {
    # Strip off all args up to and including "--args"
    m <- match("--args", argv, 0L)
    args <- if (m) argv[-seq_len(m)] else character()
  }

  # After processing, we should be left with args like this:
  # [1] "-s"
  # [2] "S2kkmshsqwmkhhfb16fk"
  # [3] "-c"
  # [4] "C2kkmsjs57a10jvzx855"
  list(script = script_path, argv = args)
}

# Load required libraries used for Rscripts
# This is handled by rserve_preload.R in Rserve case
load_required_libraries <- function() {
  return(TRUE)

  libraries <- c(
    "doParallel", "httr", "itertools",
    "jose", "openssl",
    "parallel", "plyr", "R6", "synchronicity",
    "sys", "tools", "ulid", "unix", "utils", "withr"
  )

  threshold <- futile.logger::flog.threshold(futile.logger::TRACE,
    name = "installer"
  )
  ow <- options("warn")
  options(warn = 1)
  for (lib in libraries) {
    library(lib, character.only = TRUE, warn.conflicts = FALSE, quietly = TRUE)
    futile.logger::flog.trace(paste(lib, "was installed."),
      name = "installer"
    )
  }
  options(ow)
  TRUE
}
