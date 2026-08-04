import os
import subprocess
import tempfile
import atexit
import winreg
from contextlib import contextmanager

_REG = r"Software\CASD\Hadoop"
_job_dt = None


def conf_registre():
    """Lit la configuration deposee par install-tokens.ps1."""
    try:
        k = winreg.OpenKey(winreg.HKEY_CURRENT_USER, _REG)
    except OSError:
        raise RuntimeError(
            "Configuration absente dans HKCU\\%s.\n"
            "Executer install-tokens.ps1 avant d'utiliser ce module." % _REG
        )
    valeurs = {}
    i = 0
    while True:
        try:
            nom, val, _ = winreg.EnumValue(k, i)
            valeurs[nom] = val
            i += 1
        except OSError:
            break
    winreg.CloseKey(k)
    return valeurs


def _token_session():
    """Genere un token jetable propre a cette session Python."""
    global _job_dt
    cf = conf_registre()
    dt = os.path.join(tempfile.gettempdir(), f"hadoop-py-{os.getpid()}.dt")
    ps = os.path.join(cf["ToolsPath"], "refresh-tokens.ps1")
    if not os.path.exists(ps):
        raise FileNotFoundError(f"refresh-tokens.ps1 introuvable dans {cf['ToolsPath']}")

    res = subprocess.run(
        ["powershell", "-ExecutionPolicy", "Bypass", "-File", ps,
         "-Out", dt, "-Quiet"],
        capture_output=True, text=True
    )
    if not os.path.exists(dt):
        raise RuntimeError(
            "Echec de la generation du token.\n"
            f"stdout: {res.stdout}\nstderr: {res.stderr}"
        )

    os.environ["HADOOP_TOKEN_FILE_LOCATION"] = dt
    _job_dt = dt
    print(f"Token Spark genere : {dt}")
    return dt


def _cleanup():
    """Supprime le token jetable de la session Python."""
    global _job_dt
    if _job_dt:
        crc = os.path.join(os.path.dirname(_job_dt),
                           "." + os.path.basename(_job_dt) + ".crc")
        for f in (_job_dt, crc):
            try:
                os.remove(f)
            except OSError:
                pass
        _job_dt = None
    os.environ.pop("HADOOP_TOKEN_FILE_LOCATION", None)


atexit.register(_cleanup)


def get_spark(conf=None, master="yarn", app_name="python", driver_port=None):
    """
    Ouvre une SparkSession configuree pour le cluster.

    conf : dictionnaire de proprietes Spark choisies par l'utilisateur
           (memoire, nombre d'executeurs, options applicatives).
           Les cles de securite et de placement ci-dessous sont imposees
           et ecrasent toute valeur fournie.
    """
    cf = conf_registre()

    if cf.get("SparkHome"):
        os.environ["SPARK_HOME"] = cf["SparkHome"]
    if cf.get("HadoopConf"):
        os.environ["HADOOP_CONF_DIR"] = cf["HadoopConf"]

    if master == "yarn":
        _token_session()

    from pyspark.sql import SparkSession
    b = SparkSession.builder.master(master).appName(app_name)

    # configuration de l'utilisateur, appliquee en premier
    for cle, val in (conf or {}).items():
        b = b.config(cle, str(val))

    if driver_port is None:
        driver_port = int(cf.get("DriverPort", 7077))

    b = (b.config("spark.security.credentials.hadoopfs.enabled", "false")
          .config("spark.security.credentials.hive.enabled", "false")
          .config("spark.security.credentials.hbase.enabled", "false")
          .config("spark.yarn.stagingDir",
                  f"{cf['StagingDir']}/{os.environ.get('USERNAME','')}")
          .config("spark.driver.port", str(driver_port))
          .config("spark.driver.blockManager.port", str(driver_port + 200)))
    # -----------------------------------------------------------------

    return b.getOrCreate()


def stop_spark(spark):
    """Ferme la session et fait le menage."""
    try:
        spark.stop()
    finally:
        _cleanup()


@contextmanager
def spark_session(**kwargs):
    """Gestionnaire de contexte : ferme et nettoie meme en cas d'erreur."""
    spark = get_spark(**kwargs)
    try:
        yield spark
    finally:
        stop_spark(spark)