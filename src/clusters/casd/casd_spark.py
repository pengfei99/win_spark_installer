import os
import subprocess
import tempfile
import winreg
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, Generator, Optional
from pyspark.sql import SparkSession

_REG_PATH: str = r"Software\CASD\Hadoop"


def get_registry_config(sub_key: str = _REG_PATH) -> Dict[str, str]:
    """Reads Windows Registry values into a dictionary using a safe context manager."""
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sub_key) as key:
            values: Dict[str, str] = {}
            index = 0
            while True:
                try:
                    name, val, _ = winreg.EnumValue(key, index)
                    values[name] = str(val)
                    index += 1
                except OSError:
                    break
            return values
    except OSError as err:
        raise RuntimeError(
            f"Configuration missing in HKCU\\{sub_key}.\n"
            "Run install-tokens.ps1 before using this module."
        ) from err


class HadoopTokenManager:
    """Manages the disposable Hadoop session token lifecycle safely."""

    def __init__(self, config: Optional[Dict[str, str]] = None) -> None:
        self.config = config or get_registry_config()
        self.token_path: Optional[Path] = None

    def generate_token(self) -> Path:
        """Generates a session token using PowerShell script."""
        tools_path = Path(self.config.get("ToolsPath", ""))
        ps_script = tools_path / "refresh-tokens.ps1"

        if not ps_script.is_file():
            raise FileNotFoundError(f"Script missing at: {ps_script}")

        pid = os.getpid()
        token_file = Path(tempfile.gettempdir()) / f"hadoop-py-{pid}.dt"

        # Explicit powershell executable with -NoProfile for faster, clean execution
        cmd = [
            "powershell.exe",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", str(ps_script),
            "-Out", str(token_file),
            "-Quiet"
        ]

        res = subprocess.run(cmd, capture_output=True, text=True, check=False)

        if not token_file.is_file():
            raise RuntimeError(
                "Failed to generate session token.\n"
                f"stdout: {res.stdout}\nstderr: {res.stderr}"
            )

        os.environ["HADOOP_TOKEN_FILE_LOCATION"] = str(token_file)
        self.token_path = token_file
        return token_file

    def cleanup(self) -> None:
        """Removes the generated token file and its accompanying .crc file."""
        if self.token_path and self.token_path.exists():
            crc_file = self.token_path.parent / f".{self.token_path.name}.crc"
            for file_target in (self.token_path, crc_file):
                try:
                    file_target.unlink(missing_ok=True)
                except OSError:
                    pass
            self.token_path = None

        os.environ.pop("HADOOP_TOKEN_FILE_LOCATION", None)


def get_spark(
    conf: Optional[Dict[str, Any]] = None,
    master: str = "yarn",
    app_name: str = "python",
    driver_port: Optional[int] = None,
    token_manager: Optional[HadoopTokenManager] = None
):
    """Initializes and returns a SparkSession configured for the target environment."""
    cfg = get_registry_config()

    if "SparkHome" in cfg:
        os.environ["SPARK_HOME"] = cfg["SparkHome"]
    if "HadoopConf" in cfg:
        os.environ["HADOOP_CONF_DIR"] = cfg["HadoopConf"]

    if master == "yarn":
        mgr = token_manager or HadoopTokenManager(cfg)
        mgr.generate_token()

    builder = SparkSession.builder.master(master).appName(app_name)

    # Apply user configurations first
    if conf:
        for key, value in conf.items():
            builder = builder.config(key, str(value))

    port = driver_port if driver_port is not None else int(cfg.get("DriverPort", 7077))
    username = os.environ.get("USERNAME", "default")
    staging_dir = Path(cfg.get("StagingDir", "/tmp")) / username

    builder = (
        builder
        .config("spark.security.credentials.hadoopfs.enabled", "false")
        .config("spark.security.credentials.hive.enabled", "false")
        .config("spark.security.credentials.hbase.enabled", "false")
        .config("spark.yarn.stagingDir", staging_dir.as_posix())
        .config("spark.driver.port", str(port))
        .config("spark.driver.blockManager.port", str(port + 200))
    )

    return builder.getOrCreate()


@contextmanager
def spark_session(
    conf: Optional[Dict[str, Any]] = None,
    **kwargs: Any
) -> Generator[Any, None, None]:
    """Context manager for SparkSession that ensures proper cleanup on termination."""
    cfg = get_registry_config()
    token_mgr = HadoopTokenManager(cfg) if kwargs.get("master", "yarn") == "yarn" else None

    spark = get_spark(conf=conf, token_manager=token_mgr, **kwargs)
    try:
        yield spark
    finally:
        try:
            spark.stop()
        finally:
            if token_mgr:
                token_mgr.cleanup()