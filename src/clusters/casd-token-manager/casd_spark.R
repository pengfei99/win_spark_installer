# Private package/script environment for internal state management
.CASD <- new.env(parent = emptyenv())
.CASD$jobDt <- NULL

#' Read CASD Hadoop Configuration from Windows Registry
#' @return list containing registry keys
casd_conf <- function() {
  if (.Platform$OS.type != "windows") {
    stop("Ce helper est prévu pour Windows.", call. = FALSE)
  }

  r <- try(
    utils::readRegistry("Software\\CASD\\Hadoop", hive = "HCU"),
    silent = TRUE
  )

  if (inherits(r, "try-error") || is.null(r$ToolsPath)) {
    stop(
      "Configuration absente dans HKCU\\Software\\CASD\\Hadoop.\n",
      "Exécuter install-tokens.ps1 avant d'utiliser ce helper.",
      call. = FALSE
    )
  }
  r
}

#' Generate Session-Specific Disposable Token
#' @return Invisibly returns path to the generated delegation token file
casd_token_session <- function() {
  cf <- casd_conf()
  dt <- file.path(Sys.getenv("TEMP"), sprintf("hadoop-r-%d.dt", Sys.getpid()))
  ps <- file.path(cf$ToolsPath, "refresh-tokens.ps1")

  if (!file.exists(ps)) {
    stop("refresh-tokens.ps1 introuvable dans ", cf$ToolsPath, call. = FALSE)
  }

  sortie <- system2(
    "powershell",
    c("-ExecutionPolicy", "Bypass",
      "-File", shQuote(ps),
      "-Out", shQuote(dt),
      "-Quiet"),
    stdout = TRUE,
    stderr = TRUE
  )

  if (!file.exists(dt)) {
    stop(
      "Échec de la génération du token :\n",
      paste(sortie, collapse = "\n"),
      call. = FALSE
    )
  }

  Sys.setenv(HADOOP_TOKEN_FILE_LOCATION = dt)
  .CASD$jobDt <- dt
  message("Token Spark généré : ", dt)
  invisible(dt)
}

#' Connect to Spark on YARN with CASD Security Policies
#' @param config Optional base spark_config list
#' @param master Execution mode (default: "yarn")
#' @param app_name Application name in YARN Resource Manager
#' @param driver_port Port allocated for the Spark driver
#' @return sparklyr connection object (sc)
casd_spark_connect <- function(config = NULL,
                               master = "yarn",
                               app_name = "rstudio",
                               driver_port = NULL) {

  if (!requireNamespace("sparklyr", quietly = TRUE)) {
    stop("Le paquet sparklyr n'est pas installé.", call. = FALSE)
  }

  cf <- casd_conf()

  if (nzchar(cf$SparkHome))  Sys.setenv(SPARK_HOME      = cf$SparkHome)
  if (nzchar(cf$HadoopConf)) Sys.setenv(HADOOP_CONF_DIR = cf$HadoopConf)

  if (master == "yarn") {
    casd_token_session()
  }

  cfg <- if (is.null(config)) sparklyr::spark_config() else config

  if (is.null(driver_port)) {
    driver_port <- if (!is.null(cf$DriverPort)) as.integer(cf$DriverPort) else 7077L
  }

  # Security & Networking configuration for secure CASD environment
  cfg$spark.security.credentials.hadoopfs.enabled <- "false"
  cfg$spark.security.credentials.hive.enabled     <- "false"
  cfg$spark.security.credentials.hbase.enabled    <- "false"

  cfg$spark.driver.port                           <- driver_port
  cfg$spark.driver.blockManager.port              <- driver_port + 200L

  sparklyr::spark_connect(
    master    = master,
    app_name  = app_name,
    config    = cfg,
    spark_home = Sys.getenv("SPARK_HOME")
  )
}

#' Disconnect Spark Connection and Clean Up Temporary Security Tokens
#' @param sc Spark connection object
#' @return Invisibly returns TRUE
casd_spark_disconnect <- function(sc) {
  try(sparklyr::spark_disconnect(sc), silent = TRUE)

  if (!is.null(.CASD$jobDt)) {
    crc <- file.path(dirname(.CASD$jobDt), paste0(".", basename(.CASD$jobDt), ".crc"))
    unlink(c(.CASD$jobDt, crc), force = TRUE)
    .CASD$jobDt <- NULL
  }

  Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
  invisible(TRUE)
}

# Automatic memory leak prevention & token garbage collection
reg.finalizer(.CASD, function(e) {
  if (!is.null(e$jobDt)) {
    crc <- file.path(dirname(e$jobDt), paste0(".", basename(e$jobDt), ".crc"))
    unlink(c(e$jobDt, crc), force = TRUE)
  }
}, onexit = TRUE)
}