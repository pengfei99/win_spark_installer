
.CASD <- new.env()
.CASD$jobDt < - NULL

# configuration : lue dans la base de registre
casd_conf < - function()
{
if (.Platform$OS.type != "windows")
stop("Ce helper est prevu pour Windows.")
r < -
try(utils::
    readRegistry("Software\\CASD\\Hadoop", hive="HCU"), silent = TRUE)
if (inherits(r, "try-error") | | is.null(r$ToolsPath)) {
stop("Configuration absente dans HKCU\\Software\\CASD\\Hadoop.\n",
"Executer install-tokens.ps1 avant d'utiliser ce helper.")
}
r
}

# token jetable propre a la session R
casd_token_session < - function()
{
cf < - casd_conf()
dt < - file.path(Sys.getenv("TEMP"), sprintf("hadoop-r-%d.dt", Sys.getpid()))
ps < - file.path(cf$ToolsPath, "refresh-tokens.ps1")
if (!file.exists(ps)) stop("refresh-tokens.ps1 introuvable dans ", cf$ToolsPath)

sortie < - system2("powershell",
                   c("-ExecutionPolicy", "Bypass", "-File", shQuote(ps),
                     "-Out", shQuote(dt), "-Quiet"),
                   stdout=TRUE, stderr=TRUE)
if (!file.exists(dt)) {
stop("Echec de la generation du token :\n", paste(sortie, collapse = "\n"))
}
Sys.setenv(HADOOP_TOKEN_FILE_LOCATION=dt)
.CASD$jobDt < - dt
message("Token Spark genere : ", dt)
invisible(dt)
}

# connexion

casd_spark_connect < - function(config=NULL,
master = "yarn",
app_name = "rstudio",
driver_port = NULL) {

if (!requireNamespace("sparklyr", quietly = TRUE)) {
stop("Le paquet sparklyr n'est pas installe.")
}
cf < - casd_conf()

if (nzchar(cf$SparkHome))  Sys.setenv(SPARK_HOME      = cf$SparkHome)
if (nzchar(cf$HadoopConf)) Sys.setenv(HADOOP_CONF_DIR = cf$HadoopConf)

if (master == "yarn") casd_token_session()

cfg < - if (is.null(config)) sparklyr::spark_config() else config
if (is.null(driver_port)) {
driver_port < - if (! is.null(cf$DriverPort)) as.integer(cf$DriverPort) else 7077L
}

#
# Configuration imposee : securite, placement, ports.
cfg$spark.security.credentials.hadoopfs.enabled < - "false"
cfg$spark.security.credentials.hive.enabled < - "false"
cfg$spark.security.credentials.hbase.enabled < - "false"
cfg$spark.yarn.stagingDir < - paste0(cf$StagingDir, "/", Sys.getenv("USERNAME"))
cfg$spark.driver.port < - driver_port
cfg$spark.driver.blockManager.port < - driver_port + 200

sparklyr::spark_connect(master=master,
                        app_name=app_name,
                        config=cfg,
                        spark_home=Sys.getenv("SPARK_HOME"))
}

# deconnexion et menage
casd_spark_disconnect < - function(sc)
{
try(sparklyr::
    spark_disconnect(sc), silent = TRUE)
if (! is.null(.CASD$jobDt)) {
crc < - file.path(dirname(.CASD$jobDt), paste0(".", basename(.CASD$jobDt), ".crc"))
unlink(c(.CASD$jobDt, crc))
.CASD$jobDt < - NULL
}
# on rend la main au token de session, utilise par les commandes hdfs
cf < -
try(casd_conf(), silent = TRUE)
if (!inherits(cf, "try-error")) {
sess < - file.path(cf$TokenDir, "")  # le token de session est nomme par PID PowerShell
Sys.unsetenv("HADOOP_TOKEN_FILE_LOCATION")
}
invisible(TRUE)
}

# menage automatique si la session R se ferme sans disconnect explicite
if (exists(".CASD", inherits=FALSE)) {
reg.finalizer(.CASD, function(e)
{
if (! is.null(e$jobDt)) unlink(e$jobDt)
}, onexit = TRUE)
}