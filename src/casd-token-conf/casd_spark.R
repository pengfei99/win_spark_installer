# =====================================================================
# CASD sparklyr + Hadoop delegation token helper
# =====================================================================
#
# High-level workflow:
#
# 1. Read CASD configuration from the Windows registry.
# 2. If connecting to YARN:
#    - generate a temporary Hadoop delegation token file
#    - set HADOOP_TOKEN_FILE_LOCATION to that file
# 3. Connect to Spark using sparklyr.
# 4. On disconnect:
#    - disconnect Spark
#    - delete the temporary token file
#    - restore/unset HADOOP_TOKEN_FILE_LOCATION
#
# Important design choice:
# - We use an environment (.casd_state) as hidden mutable state.
# - This avoids polluting the global namespace with many variables.
# - It also allows functions to share and update state over time.
# =====================================================================

# =====================================================================
# USER CONFIGURATION
# =====================================================================
# Modify these values to customize the behavior of the script
# without touching the core logic below.
# =====================================================================

# 1. REGISTRY CONFIGURATION
# The Windows Registry path (under HKEY_CURRENT_USER) where CASD
# Hadoop configuration (ToolsPath, SparkHome, etc.) is stored.
CASD_REGISTRY_PATH <- "Software\\CASD\\Hadoop"

# 2. TOKEN GENERATION CONFIGURATION
# Name of the PowerShell script used to generate tokens.
# This script is expected to be located in the ToolsPath defined in the registry.
CASD_TOKEN_SCRIPT_NAME <- "refresh-tokens.ps1"

# Prefix and file extension for the temporary token files created in tempdir().
CASD_TOKEN_PREFIX <- "hadoop-r-"
CASD_TOKEN_EXT    <- ".dt"

# Timeout in seconds for the PowerShell token generation script.
# Set to 0 for no timeout.
CASD_DEFAULT_TIMEOUT <- 60L

# 3. SPARK CONNECTION DEFAULTS
# Default Spark master URL and application name.
CASD_DEFAULT_MASTER   <- "yarn"
CASD_DEFAULT_APP_NAME <- "rstudio"

# Default driver port.
# NULL means let Spark choose a random available port (Recommended for multiple sessions).
# Set to an integer (e.g., 7077L) to force a specific port.
CASD_DEFAULT_DRIVER_PORT <- 7077L

# Offset added to the driver port to calculate the block manager port.
# E.g., if driver port is 7077, block manager port will be 7277.
CASD_BLOCK_MANAGER_OFFSET <- 200L

# 4. SPARK SECURITY CONFIGURATION
# Spark credential providers to disable.
# Because this helper manually manages HADOOP_TOKEN_FILE_LOCATION, we disable
# Spark's built-in credential providers to prevent conflicts.
# Set to character(0) or NULL if you want Spark to manage these automatically.
CASD_DISABLED_CREDENTIALS <- c(
  "spark.security.credentials.hadoopfs.enabled",
  "spark.security.credentials.hive.enabled",
  "spark.security.credentials.hbase.enabled"
)


# ---------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------

# .casd_state is a hidden mutable environment.
#
# Why an environment?
# - R function environments allow mutation without using global variables to avoid namespace pollution.
# - This acts like a private "singleton" object which works across on all functions.
#
# Fields:
# - tokens:
#     Tracks all token files created by this helper.
#     Key: token file basename
#     Value: full normalized token file path
#
# - last_token:
#     The most recently generated token path.
#
# - has_original_token_env:
#     TRUE if we saved the user's original HADOOP_TOKEN_FILE_LOCATION.
#
# - original_token_env:
#     The original value of HADOOP_TOKEN_FILE_LOCATION before we changed it.
#     If it was blank, we store NA_character_.
# ---------------------------------------------------------------------

.casd_state <- new.env(parent = emptyenv())
.casd_state$tokens <- new.env(parent = emptyenv())
.casd_state$last_token <- NULL

.casd_state$has_original_token_env <- FALSE
.casd_state$original_token_env <- NULL

# ---------------------------------------------------------------------
# NULL-coalescing operator
# ---------------------------------------------------------------------
#
# x %||% y returns:
# - x if x is not NULL
# - y if x is NULL
#
# This is useful for fallback logic, for example:
# final_port <- explicit_port %||% config_port %||% registry_port
# ---------------------------------------------------------------------
`%||%` <- function(x, y) {
  if (is.null(x)) y else x
}

# ---------------------------------------------------------------------
# Internal helper: check if OS is Windows
# ---------------------------------------------------------------------
#
# This helper is designed for Windows only because it reads the
# Windows registry and uses PowerShell.
# ---------------------------------------------------------------------
#' @noRd
.casd_is_windows <- function() {
  .Platform$OS.type == "windows"
}

# ---------------------------------------------------------------------
# Internal helper: check whether a value is blank/empty
# ---------------------------------------------------------------------
#
# This is used for optional config values.
#
# Examples of blank values:
# - NULL
# - character(0)
# - ""
# - "   "
# - NA
# ---------------------------------------------------------------------
#' @noRd
.casd_is_blank <- function(x) {
  if (is.null(x) || length(x) == 0L) return(TRUE)

  # Try converting to character.
  val <- tryCatch(
    as.character(x),
    error = function(e) NA_character_
  )

  # Remove NA values.
  val <- val[!is.na(val)]

  # If nothing remains, it is blank.
  if (length(val) == 0L) return(TRUE)

  # If all remaining values are empty/whitespace-only, it is blank.
  !any(nzchar(trimws(val)))
}

# ---------------------------------------------------------------------
# Internal helper: safely extract the first character value
# ---------------------------------------------------------------------
#
# Registry values can sometimes be:
# - NULL
# - empty
# - numeric
# - character vectors
# - quoted strings
#
# This function tries to convert the first element to a clean string.
#
# Returns:
# - A cleaned string if available
# - NA_character_ if missing/empty/invalid
# ---------------------------------------------------------------------
#' @noRd
.casd_first_chr <- function(x) {
  # If the input is missing or empty, return NA.
  if (is.null(x) || length(x) == 0L) return(NA_character_)

  # Try to convert the first element to character.
  val <- tryCatch(
    as.character(x[1L]),
    error = function(e) NA_character_
  )

  # If conversion failed or produced NA, return NA.
  if (length(val) == 0L || is.na(val)) return(NA_character_)

  # Remove surrounding whitespace.
  val <- trimws(val)

  # Remove accidental surrounding double quotes.
  #
  # Example:
  # "\"C:\\CASD\"" becomes "C:\CASD"
  val <- gsub('^"|"$', "", val)

  # Remove whitespace again after quote removal.
  val <- trimws(val)

  # If the result is empty, treat it as missing.
  if (!nzchar(val)) NA_character_ else val
}

# ---------------------------------------------------------------------
# Internal helper: normalize a path if it looks valid
# ---------------------------------------------------------------------
#
# normalizePath() converts paths to a standard absolute form.
#
# We use mustWork = FALSE because some configured directories may not
# exist yet, and we want to warn later instead of failing immediately.
# ---------------------------------------------------------------------
#' @noRd
.casd_normalize_path <- function(x) {
  if (is.character(x) && length(x) == 1L && !is.na(x) && nzchar(x)) {
    normalizePath(x, mustWork = FALSE)
  } else {
    x
  }
}

# ---------------------------------------------------------------------
# Internal helper: set environment variable only if blank
# ---------------------------------------------------------------------
#
# This is a safer default than overwriting existing environment vars.
#
# Example:
# If SPARK_HOME is already set by the user, we leave it alone.
#
# If your CASD environment requires registry values to override the
# current environment, replace calls to this function with direct
# Sys.setenv() calls.
# ---------------------------------------------------------------------
#' @noRd
.casd_set_env_if_blank <- function(name, value) {
  # Only set the environment variable if:
  # - value is a non-missing string
  # - value is not empty
  # - current environment variable is blank/unset
  if (is.character(value) &&
      length(value) == 1L &&
      !is.na(value) &&
      nzchar(value) &&
      !nzchar(Sys.getenv(name))) {

    # R does not allow direct dynamic naming like:
    # Sys.setenv(name = value)
    #
    # So we build a named list and call Sys.setenv() with do.call().
    envs <- list(value)
    names(envs) <- name
    do.call(Sys.setenv, envs)
  }

  invisible(Sys.getenv(name))
}
# ---------------------------------------------------------------------
# Internal helper: locate PowerShell executable
# ---------------------------------------------------------------------
#
# We try common PowerShell executable names.
#
# Order:
# 1. Windows PowerShell: powershell.exe
# 2. PowerShell Core: pwsh.exe
# 3. Unqualified names, in case PATH resolution works differently
#
# If nothing is found, we still return "powershell" so the later
# system2() call can produce a standard "command not found" error.
# ---------------------------------------------------------------------
#' @noRd
.casd_find_powershell <- function() {
  for (exe in c("powershell.exe", "pwsh.exe", "powershell", "pwsh")) {
    path <- unname(Sys.which(exe))

    # Sys.which returns "" when the executable is not found.
    if (nzchar(path)) return(path)
  }

  "powershell"
}

# ---------------------------------------------------------------------
# Internal helper: parse and validate a network port
# ---------------------------------------------------------------------
#
# Accepts:
# - numeric ports: 7077
# - character ports: "7077"
#
# Returns:
# - integer port if valid
# - NULL if missing/invalid
#
# Valid range: 1 to 65535, because blockManagerPort is driver_port+max_user_count
# ---------------------------------------------------------------------
#' @noRd
.casd_parse_port <- function(x) {
  # Missing input.
  if (is.null(x) || length(x) == 0L) return(NULL)

  # Convert to integer.
  # suppressWarnings() is used because as.integer("abc") warns.
  p <- if (is.numeric(x)) {
    suppressWarnings(as.integer(x[1L]))
  } else {
    suppressWarnings(as.integer(as.character(x[1L])))
  }

  # If conversion failed, return NULL.
  if (length(p) == 0L || is.na(p)) return(NULL)

  # Ports must be between 1 and 65535-400.
  if (p < 1L || p > 65135L) return(NULL)

  p
}


# =====================================================================
# Read CASD configuration from Windows registry
# =====================================================================
#
# Expected registry location:
#
#   HKEY_CURRENT_USER\Software\CASD\Hadoop
#
# Expected values inside that key:
#
#   ToolsPath   Required. Folder containing refresh-tokens.ps1.
#   SparkHome   Optional. SPARK_HOME.
#   HadoopConf  Optional. HADOOP_CONF_DIR.
#   DriverPort  Optional. Default Spark driver port.
#
# Return value:
#
#   list(
#     ToolsPath = "...",
#     SparkHome = "...",
#     HadoopConf = "...",
#     DriverPort = "..."
#   )
#
# Missing optional values are returned as NA_character_.
# =====================================================================
#' @return A list containing Hadoop and Spark configurations.
#' @noRd
get_casd_conf <- function() {
  # This helper is Windows-only because it uses readRegistry().
  if (!.casd_is_windows()) {
    stop(
      "OS Error: This helper is designed exclusively for Windows environments.",
      call. = FALSE
    )
  }

  # Read registry key.
  # If the key does not exist or cannot be read, return NULL.
  conf <- tryCatch({
    utils::readRegistry(CASD_REGISTRY_PATH, hive = "HCU")
  }, error = function(e) NULL)

  # If the registry key is missing, fail with installation guidance.
  if (is.null(conf)) {
    stop(
      sprintf("Configuration Error: Missing registry key 'HKCU\\%s'.\n", CASD_REGISTRY_PATH),
      "Please run 'install-tokens.ps1' before using this helper.",
      call. = FALSE
    )
  }

  # ToolsPath is required.
  tools_path <- .casd_first_chr(conf$ToolsPath)

  if (is.na(tools_path)) {
    stop(
      sprintf("Configuration Error: Missing 'ToolsPath' value in 'HKCU\\%s'.", CASD_REGISTRY_PATH),
      call. = FALSE
    )
  }

  # Return a normalized configuration list.
  #
  # Optional values may be NA_character_.
  list(
    ToolsPath  = .casd_normalize_path(tools_path),
    SparkHome  = .casd_normalize_path(.casd_first_chr(conf$SparkHome)),
    HadoopConf = .casd_normalize_path(.casd_first_chr(conf$HadoopConf)),
    DriverPort = .casd_first_chr(conf$DriverPort)
  )
}


# =====================================================================
# Generate an ephemeral Hadoop delegation token file
# =====================================================================
#
# This function:
#
# 1. Reads CASD config.
# 2. Finds refresh-tokens.ps1.
# 3. Creates a temporary output path.
# 4. Runs PowerShell:
#
#      refresh-tokens.ps1 -Out <tempfile> -Quiet
#
# 5. Confirms that the token file was created and is not empty.
# 6. Sets HADOOP_TOKEN_FILE_LOCATION.
# 7. Saves the token path in .casd_state for later cleanup.
#
# Return value:
#
#   Normalized path to the generated token file.
#
# Side effects:
#
#   - Creates a temp token file.
#   - Sets HADOOP_TOKEN_FILE_LOCATION.
#   - Updates .casd_state.
# =====================================================================
#' @return The normalized file path to the generated token.
#' @noRd
generate_casd_token <- function(timeout = CASD_DEFAULT_TIMEOUT) {
  # Load CASD configuration from registry.
  cf <- get_casd_conf()

  # build full path to the token generation script.
  ps_script <- normalizePath(file.path(cf$ToolsPath, CASD_TOKEN_SCRIPT_NAME), mustWork = FALSE)

  # the token generation script must exist
  if (!file.exists(ps_script)) {
    stop(sprintf("File Error: '%s' not found in '%s'.", CASD_TOKEN_SCRIPT_NAME, cf$ToolsPath), call. = FALSE)
  }

  # Temporary token file.
  #
  # tempfile() gives a unique filename, avoiding collisions between
  # multiple R sessions or repeated connections.
  dt_path <- normalizePath(
    tempfile(pattern = CASD_TOKEN_PREFIX, fileext = CASD_TOKEN_EXT),
    mustWork = FALSE
  )

  # -------------------------------------------------------------------
  # Failure cleanup for token generation
  # -------------------------------------------------------------------
  #
  # If token generation fails, we may have created a partial token file
  # or CRC file. This on.exit() hook removes them.
  #
  # success is set to TRUE only at the very end.
  # -------------------------------------------------------------------
  success <- FALSE

  on.exit({
    if (!success) {
      crc_path <- file.path(
        dirname(dt_path),
        paste0(".", basename(dt_path), ".crc")
      )

      suppressWarnings(file.remove(c(dt_path, crc_path)))
    }
  }, add = TRUE)

  # PowerShell arguments.
  #
  # -NoProfile: Not used for now
  #   Avoid loading user PowerShell profiles, making execution faster
  #   and more predictable.
  #
  # -NonInteractive:
  #   Fail instead of prompting the user.
  #
  # -ExecutionPolicy Bypass:
  #   Run the script even if the default policy is restrictive.
  #
  # shQuote():
  #   Required because paths may contain spaces.
  ps_args <- c(
    "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", shQuote(ps_script),
    "-Out", shQuote(dt_path),
    "-Quiet"
  )

  # Normalize user input timeout. if user input is not valid, use CASD_DEFAULT_TIMEOUT
  # timeout = 0 means no timeout in system2().
  timeout <- suppressWarnings(as.integer(timeout))
  if (length(timeout) == 0L || is.na(timeout) || timeout < 0L) {
    timeout <- CASD_DEFAULT_TIMEOUT
  }

  # Find PowerShell executable.
  exe <- .casd_find_powershell()

  # Build system2() arguments.
  sys_args <- list(
    command = exe,
    args = ps_args,
    stdout = TRUE,
    stderr = TRUE
  )

  # Older R versions may not support timeout.
  # Add it only if available.
  if ("timeout" %in% names(formals(system2))) {
    sys_args$timeout <- timeout
  }

  # Run PowerShell.
  #
  # stdout = TRUE and stderr = TRUE capture output as an R character
  # vector, which is useful for error reporting.
  out <- tryCatch(
    suppressWarnings(do.call(system2, sys_args)),
    error = function(e) {
      # If system2 itself fails, create a fake output object.
      structure(
        character(),
        status = -1L,
        error_message = conditionMessage(e)
      )
    }
  )

  # system2() usually attaches a status attribute only when non-zero.
  status <- attr(out, "status", exact = TRUE)
  if (is.null(status)) status <- 0L

  # Check that the token file exists and has non-zero size.
  size <- if (file.exists(dt_path)) file.info(dt_path)$size else NA_integer_

  # If PowerShell failed or token file is missing/empty, stop.
  if (status != 0L || !isTRUE(size > 0L)) {

    # If system2 itself failed, append its error message.
    err_msg <- attr(out, "error_message", exact = TRUE)
    if (!is.null(err_msg)) out <- c(out, err_msg)

    # Make empty output easier to read in error messages.
    if (length(out) == 0L) {
      out <- "(no output)"
    }

    # Avoid flooding the console if PowerShell produced lots of output.
    if (length(out) > 30L) {
      out <- c(
        utils::head(out, 15L),
        "...",
        utils::tail(out, 15L)
      )
    }

    stop(
      "Token generation failed.\n",
      "Command: ", exe, " ", paste(ps_args, collapse = " "), "\n",
      "Output:\n", paste(out, collapse = "\n"),
      call. = FALSE
    )
  }

  # -------------------------------------------------------------------
  # Preserve original HADOOP_TOKEN_FILE_LOCATION
  # -------------------------------------------------------------------
  #
  # If the user already had HADOOP_TOKEN_FILE_LOCATION set, we save it
  # once so we can restore it later.
  #
  # If it was blank, we store NA_character_ to mean "unset it later".
  # -------------------------------------------------------------------
  if (!isTRUE(.casd_state$has_original_token_env)) {
    old_env <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")

    .casd_state$original_token_env <- if (nzchar(old_env)) old_env else NA_character_
    .casd_state$has_original_token_env <- TRUE
  }

  # Hadoop/Spark client libraries read this environment variable to
  # locate delegation token credentials.
  Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = dt_path)

  # Track token in state.
  #
  # The key is the basename because environment object names should be
  # simple strings.
  token_id <- basename(dt_path)
  .casd_state$tokens[[token_id]] <- dt_path

  # track as the latest token.
  .casd_state$last_token <- dt_path

  # Mark generation as successful so on.exit() does not delete the file.
  success <- TRUE

  message(sprintf("[OK] Spark YARN token generated: %s", dt_path))

  invisible(dt_path)
}

# =====================================================================
# Clean up one token file
# =====================================================================
#
# This function:
#
# 1. Deletes the token file.
# 2. Deletes the matching Hadoop CRC file if present.
# 3. Removes the token from .casd_state$tokens.
# 4. Updates .casd_state$last_token if needed.
# 5. Restores or unsets HADOOP_TOKEN_FILE_LOCATION.
#
# If token_path is NULL, it cleans the most recent token.
# =====================================================================
#' @noRd
.casd_cleanup_token <- function(token_path = NULL) {

  # Default to the last generated token.
  if (is.null(token_path)) {
    token_path <- .casd_state$last_token
  }

  # If there is no valid token path, do nothing.
  if (is.null(token_path) ||
      !is.character(token_path) ||
      length(token_path) != 1L ||
      is.na(token_path) ||
      !nzchar(token_path)) {
    return(invisible(FALSE))
  }

  # Normalize path so comparisons are stable.
  token_path <- normalizePath(token_path, mustWork = FALSE)

  # Hadoop often creates a CRC file next to credential files:
  #
  #   file.dt
  #   .file.dt.crc
  #
  # We try to delete both.
  crc_path <- file.path(
    dirname(token_path),
    paste0(".", basename(token_path), ".crc")
  )

  suppressWarnings(file.remove(c(token_path, crc_path)))

  # Remove this token from the tracked tokens environment.
  if (is.environment(.casd_state$tokens)) {
    for (key in ls(.casd_state$tokens)) {
      if (identical(.casd_state$tokens[[key]], token_path)) {
        rm(list = key, envir = .casd_state$tokens)
      }
    }
  }

  # If we removed the latest token, clear latest tracking fields.
  if (identical(.casd_state$last_token, token_path)) {
    .casd_state$last_token <- NULL
  }
  # -------------------------------------------------------------------
  # Restore HADOOP_TOKEN_FILE_LOCATION
  # -------------------------------------------------------------------
  #
  # We only change the environment variable if it currently points to
  # the token we just deleted.
  #
  # Cases:
  #
  # 1. Other CASD tokens still exist:
  #      Point HADOOP_TOKEN_FILE_LOCATION to one remaining token.
  #
  # 2. No CASD tokens remain:
  #      Restore original user value if we saved one.
  #      If original was blank, unset the variable.
  # -------------------------------------------------------------------
  current_env <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")

  if (nzchar(current_env)) {
    current_env <- tryCatch(
      normalizePath(current_env, mustWork = FALSE),
      error = function(e) current_env
    )
  }

  if (identical(current_env, token_path)) {

    # Collect remaining tracked token paths.
    remaining <- character(0)

    if (is.environment(.casd_state$tokens)) {
      remaining <- unlist(as.list(.casd_state$tokens), use.names = FALSE)

      # Keep only non-empty character paths.
      remaining <- remaining[
        is.character(remaining) &
        !is.na(remaining) &
        nzchar(remaining)
      ]

      remaining <- unique(remaining)
    }

    if (length(remaining) > 0L) {
      # If there are multiple tokens, prefer the current last_token.
      new_env <- if (!is.null(.casd_state$last_token) &&
                     .casd_state$last_token %in% remaining) {
        .casd_state$last_token
      } else {
        remaining[length(remaining)]
      }

      Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = new_env)

    } else if (isTRUE(.casd_state$has_original_token_env)) {
      orig <- .casd_state$original_token_env

      # Restore original if it was a non-empty string.
      if (is.character(orig) &&
          length(orig) == 1L &&
          !is.na(orig) &&
          nzchar(orig)) {
        Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = orig)
      } else {
        # Original was blank/unset.
        Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
      }

      # Clear saved original value.
      .casd_state$has_original_token_env <- FALSE
      .casd_state$original_token_env <- NULL

    } else {
      # No original value saved; simply unset.
      Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
    }
  }

  invisible(TRUE)
}


# =====================================================================
# Connect to Spark in the CASD environment
# =====================================================================
#
# Main user-facing function.
#
# What it does:
#
# 1. Checks that sparklyr is installed.
# 2. Reads CASD configuration from registry.
# 3. Optionally fills SPARK_HOME and HADOOP_CONF_DIR.
# 4. Builds sparklyr config.
# 5. Disables selected Spark credential providers.
# 6. Resolves driver port.
# 7. If master is YARN:
#      generates delegation token.
# 8. Calls sparklyr::spark_connect().
# 9. Attaches token path to the returned connection object.
#
# Return value:
#
#   sparklyr connection object.
#
# Important:
#
#   If spark_connect() fails, the generated token is cleaned up.
#   Added `...` as argument so `extra_args <- list(...)` doesn't crash R
# =====================================================================
#' @param config Optional sparklyr configuration object.
#' @param master Spark master URL (default: "yarn").
#' @param app_name Name of the Spark application.
#' @param driver_port Integer specifying the Spark driver port.
#' @return A sparklyr connection object.
#' @export
casd_spark_connect <- function(config = NULL,
                               master = "yarn",
                               app_name = "rstudio",
                               driver_port = NULL,
                               ...) {

 # Checks if the package is installed without attaching it to the global search path
  if (!requireNamespace("sparklyr", quietly = TRUE)) {
    stop("Package Error: 'sparklyr' is required but not installed.", call. = FALSE)
  }

 # Validate user input spark session master value.
  if (!is.character(master) ||
      length(master) != 1L ||
      is.na(master) ||
      !nzchar(master)) {
    stop(
      "Configuration Error: `master` must be a non-empty string.",
      call. = FALSE
    )
  }

  # Normalize master string.
  master <- trimws(master)

  # Read CASD registry configuration.
  cf <- get_casd_conf()

  # Safely set environment variables only if they exist and are valid strings
  # -------------------------------------------------------------------
  # Environment configuration
  # -------------------------------------------------------------------
  #
  # By default, we only set these if blank.
  #
  # If you want registry values to override existing values, replace:
  #
  #   .casd_set_env_if_blank(...)
  #
  # with:
  #
  #   if (!is.na(cf$SparkHome) && nzchar(cf$SparkHome)) {
  #     Sys.setenv(SPARK_HOME = cf$SparkHome)
  #   }
  # -------------------------------------------------------------------
  .casd_set_env_if_blank("SPARK_HOME", cf$SparkHome)
  .casd_set_env_if_blank("HADOOP_CONF_DIR", cf$HadoopConf)

  # -------------------------------------------------------------------
  # Build Spark config
  # -------------------------------------------------------------------
  #
  # If user did not provide config, start from sparklyr::spark_config().
  # Otherwise, use the user-provided config list.
  # -------------------------------------------------------------------
  cfg <- if (is.null(config)) sparklyr::spark_config() else config

  if (!is.list(cfg)) {
    stop(
      "Configuration Error: `config` must be NULL, a list, or sparklyr::spark_config().",
      call. = FALSE
    )
  }

  # -------------------------------------------------------------------
  # CASD security constraints
  # -------------------------------------------------------------------
  #
  # We rely on manually provided delegation
  # tokens. The below settings prevent Spark from trying to generate other
  # credential tokens automatically.
  # -------------------------------------------------------------------
  for (cred in CASD_DISABLED_CREDENTIALS) cfg[[cred]] <- "false"

  # -------------------------------------------------------------------
  # Driver port resolution
  # -------------------------------------------------------------------
  #
  # Precedence:
  #
  # 1. Explicit driver_port argument.
  # 2. Existing config value: spark.driver.port.
  # 3. Registry value: DriverPort.
  #
  # If none are valid, no driver port is forced.
  # This allows Spark to choose a random port.
  # -------------------------------------------------------------------

  # if driver_port is not valid, the function return a null value
  user_input_port <- .casd_parse_port(driver_port)

  # If the user explicitly supplied a bad port, fail.
  if (!.casd_is_blank(driver_port) && is.null(user_input_port)) {
    stop(
      "Configuration Error: `driver_port` must be an integer between 1 and 65535.",
      call. = FALSE
    )
  }

  config_port   <- .casd_parse_port(cfg[["spark.driver.port"]])
  registry_port <- .casd_parse_port(cf$DriverPort)

  # the overwrite priority is function argument > user input spark config  > win registry > CASD_DEFAULT_DRIVER_PORT
  final_driver_port <- user_input_port %||% config_port %||% registry_port %||% CASD_DEFAULT_DRIVER_PORT

  if (!is.null(final_driver_port)) {
    # setup driver port
    cfg[["spark.driver.port"]] <- as.character(final_driver_port)

    # ---------------------------------------------------------------
    # Block manager port
    # ---------------------------------------------------------------
    #
    # Original script used:
    #
    #   blockManager.port = driver.port + 200
    #
    # We only set this if:
    # - user/config did not already set it
    # - the resulting port is valid
    # ---------------------------------------------------------------
    if (is.null(cfg[["spark.driver.blockManager.port"]])) {
      bm_port <- final_driver_port + CASD_BLOCK_MANAGER_OFFSET

      # last check on blockManager port
      if (bm_port <= 65535L) {
        cfg[["spark.driver.blockManager.port"]] <- as.character(bm_port)
      } else {
        warning(
          "Port Warning: driver_port + 200 exceeds 65535; leaving blockManager port unset.",
          call. = FALSE
        )
      }
    }
  }

  # -------------------------------------------------------------------
  # Token generation for YARN
  # -------------------------------------------------------------------
  #
  # We only generate a token when connecting to YARN.
  # Local or test masters usually do not need Hadoop delegation tokens.
  # -------------------------------------------------------------------
  token_path <- NULL
  cleanup_on_error <- FALSE

  if (identical(tolower(master), "yarn")) {
    token_path <- generate_casd_token()

    # If spark_connect() fails, this flag ensures we clean up the token.
    cleanup_on_error <- TRUE

    # on.exit() runs when this function exits.
    #
    # If connection succeeds, we set cleanup_on_error <- FALSE later.
    # If connection fails or user aborts, cleanup_on_error remains TRUE.
    on.exit(
      if (cleanup_on_error) .casd_cleanup_token(token_path),
      add = TRUE
    )
  }

  # -------------------------------------------------------------------
  # SPARK_HOME handling
  # -------------------------------------------------------------------
  #
  # If SPARK_HOME is blank, pass nothing to spark_connect().
  # This lets sparklyr use its own default behavior.
  # -------------------------------------------------------------------
  spark_home <- Sys.getenv("SPARK_HOME")
  if (!nzchar(spark_home)) spark_home <- NULL

  # Warn if SPARK_HOME points to a missing directory.
  if (!is.null(spark_home) && !dir.exists(spark_home)) {
    warning(
      sprintf("Configuration Warning: SPARK_HOME '%s' does not exist.", spark_home),
      call. = FALSE
    )
  }

  # Warn if HADOOP_CONF_DIR points to a missing directory.
  hadoop_conf <- Sys.getenv("HADOOP_CONF_DIR")
  if (nzchar(hadoop_conf) && !dir.exists(hadoop_conf)) {
    warning(
      sprintf("Configuration Warning: HADOOP_CONF_DIR '%s' does not exist.", hadoop_conf),
      call. = FALSE
    )
  }

  message("[\u21BA] Connecting to Spark on ", master, "...")

  # Capture extra arguments supplied by the user.
  extra_args <- list(...)

  # Add spark_home only if:
  # - we have a non-NULL spark_home
  # - user did not already pass spark_home in ...
  if (!"spark_home" %in% names(extra_args) && !is.null(spark_home)) {
    extra_args$spark_home <- spark_home
  }

  # Build final argument list for sparklyr::spark_connect().
  connect_args <- c(
    list(
      master = master,
      app_name = app_name,
      config = cfg
    ),
    extra_args
  )

  # Connect to Spark.
  sc <- do.call(sparklyr::spark_connect, connect_args)

  # Connection succeeded.
  # Do not remove token on normal function exit.
  cleanup_on_error <- FALSE

  # -------------------------------------------------------------------
  # Attach token path to connection object
  # -------------------------------------------------------------------
  #
  # This allows casd_spark_disconnect(sc) to know which token file
  # belongs to this specific Spark connection.
  #
  # If attaching the attribute fails for some reason, we still return
  # the connection object.
  # -------------------------------------------------------------------
  if (!is.null(token_path)) {
    sc <- tryCatch(
      structure(sc, casd_token_path = token_path),
      error = function(e) sc
    )
  }

  sc
}

# =====================================================================
# Disconnect from Spark and clean up resources
# =====================================================================
#
# Main user-facing cleanup function.
#
# What it does:
#
# 1. Determines which token belongs to the connection, if possible.
# 2. Disconnects the Spark connection if it is still open.
# 3. Deletes the token file and CRC file.
# 4. Restores/unsets HADOOP_TOKEN_FILE_LOCATION.
#
# Usage:
#
#   casd_spark_disconnect(sc)
#
# You can also call:
#
#   casd_spark_disconnect()
#
# to clean the most recent token without disconnecting a connection.
# =====================================================================
#' @param sc A sparklyr connection object.
#' @export
casd_spark_disconnect <- function(sc = NULL) {

  token_path <- NULL

  if (!is.null(sc)) {
    # Preferred case:
    # casd_spark_connect() attached the token path to sc.
    token_path <- attr(sc, "casd_token_path", exact = TRUE)

    # Fallback case:
    #
    # If the connection object does not carry a token attribute, and we
    # only have one tracked token, assume that token belongs to this
    # connection.
    #
    # This is intentionally conservative. If multiple tokens exist and
    # we cannot identify the correct one, we do not guess.
    if (is.null(token_path) &&
        is.environment(.casd_state$tokens) &&
        length(ls(.casd_state$tokens)) == 1L) {
      token_path <- .casd_state$last_token
    }
  } else {
    # If no connection object was supplied, clean the last token.
    token_path <- .casd_state$last_token
  }

  # Disconnect Spark if a connection object was supplied.
  if (!is.null(sc)) {

    if (!requireNamespace("sparklyr", quietly = TRUE)) {
      warning(
        "Package Error: 'sparklyr' is required to disconnect; only token cleanup will run.",
        call. = FALSE
      )
    } else {

      # Check whether the connection is still open.
      #
      # This is wrapped in tryCatch because sc may already be invalid,
      # closed, or not a real sparklyr connection object.
      is_open <- tryCatch(
        sparklyr::spark_connection_is_open(sc),
        error = function(e) FALSE
      )

      if (isTRUE(is_open)) {
        tryCatch(
          {
            sparklyr::spark_disconnect(sc)
            message("[OK] Spark disconnected successfully.")
          },
          error = function(e) {
            warning(
              "Spark disconnection encountered an error: ",
              conditionMessage(e),
              call. = FALSE
            )
          }
        )
      } else {
        message("[INFO] Spark connection is already closed or invalid.")
      }
    }
  }

  # Clean token file, CRC file, state, and environment variable.
  .casd_cleanup_token(token_path)

  invisible(TRUE)
}


# =====================================================================
# Clean tracked CASD token files manually
# =====================================================================
#
# This is useful if:
#
# - you disconnected using sparklyr::spark_disconnect() directly
# - your script created tokens but did not clean them
# - you want to force cleanup before exiting
#
# Arguments:
#
#   all = TRUE
#     Clean all tracked token files.
#
#   all = FALSE
#     Clean only the most recent token file.
# =====================================================================
#' @export
casd_cleanup_tokens <- function(all = TRUE) {

  if (isTRUE(all) && is.environment(.casd_state$tokens)) {

    # Take a snapshot of tracked token paths.
    paths <- unique(unlist(as.list(.casd_state$tokens), use.names = FALSE))

    # Clean each tracked token.
    for (p in paths) {
      .casd_cleanup_token(p)
    }

  } else {
    # Clean only the latest token.
    .casd_cleanup_token(.casd_state$last_token)
  }

  invisible(TRUE)
}


# =====================================================================
# Finalizer: best-effort cleanup when R exits normally
# =====================================================================
#
# This finalizer deletes tracked token files when the R session ends.
#
# Important limitations:
#
# - It helps for normal R shutdown.
# - It does NOT protect against:
#     * R crashes
#     * Task Manager kill
#     * power loss
#     * kill -9 / taskkill /F
#
# This finalizer also does not disconnect Spark. It only cleans files.
# =====================================================================
reg.finalizer(
  .casd_state,
  function(env) {

    # Finalizers should be as defensive as possible.
    # We wrap everything in tryCatch so cleanup errors do not interrupt
    # R shutdown.
    tryCatch(
      {

        # Collect tracked token paths from state.
        toks <- if (is.environment(env$tokens)) as.list(env$tokens) else list()

        # Include latest token fields too, just in case.
        paths <- unlist(
          c(toks, list(env$last_token)),
          use.names = FALSE
        )

        # Nothing to clean.
        if (length(paths) == 0L) return(invisible(NULL))

        # Keep only valid non-empty character paths.
        paths <- paths[
          is.character(paths) &
          !is.na(paths) &
          nzchar(paths)
        ]

        if (length(paths) == 0L) return(invisible(NULL))

        # Normalize paths.
        paths <- unique(normalizePath(paths, mustWork = FALSE))

        # Delete each token file and its CRC file.
        for (p in paths) {
          crc <- file.path(
            dirname(p),
            paste0(".", basename(p), ".crc")
          )

          unlink(c(p, crc), force = TRUE)
        }

        # If HADOOP_TOKEN_FILE_LOCATION points to one of the deleted
        # token files, restore original value or unset it.
        current <- Sys.getenv("HADOOP_TOKEN_FILE_LOCATION")

        if (nzchar(current)) {
          current_norm <- tryCatch(
            normalizePath(current, mustWork = FALSE),
            error = function(e) current
          )

          if (current_norm %in% paths) {
            orig <- env$original_token_env

            if (is.character(orig) &&
                length(orig) == 1L &&
                !is.na(orig) &&
                nzchar(orig)) {
              Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = orig)
            } else {
              Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
            }
          }
        }

        invisible(NULL)
      },
      error = function(e) NULL
    )
  },
  onexit = TRUE
)