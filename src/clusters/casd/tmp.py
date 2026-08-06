from __future__ import annotations

import getpass
import logging
import os
import shutil
import subprocess
import tempfile
from contextlib import AbstractContextManager, contextmanager
from pathlib import Path
from typing import TYPE_CHECKING, Any, Dict, Generator, Mapping, Optional, Tuple

if TYPE_CHECKING:
    from pyspark.sql import SparkSession

try:
    import winreg
except ImportError:  # Non-Windows environments
    winreg = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

_REG_PATH: str = r"Software\CASD\Hadoop"
_TOKEN_ENV_VAR: str = "HADOOP_TOKEN_FILE_LOCATION"
_DEFAULT_TIMEOUT: float = 120.0
_BLOCK_MANAGER_PORT_OFFSET: int = 200


class RegistryConfigError(RuntimeError):
    """Raised when required registry configuration is missing or unreadable."""


class TokenError(RuntimeError):
    """Raised when a Hadoop session token cannot be created."""


def _expand_path(value: str) -> Path:
    """Expand environment variables and user home in paths, returning a Path object."""
    return Path(os.path.expandvars(os.path.expanduser(value))).resolve()


def _safe_username() -> str:
    """Return a filesystem-safe username for staging paths using standard library."""
    try:
        name = getpass.getuser()
    except Exception:
        name = os.environ.get("USERNAME") or os.environ.get("USER") or "default"
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in name)


def _validate_port(value: Any, field_name: str) -> int:
    """Validate and convert a network port value."""
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"{field_name} must be an integer port, got: {value!r}") from exc

    if not (0 <= port <= 65535):
        raise ValueError(f"{field_name} must be between 0 and 65535, got: {port}")

    return port


def get_registry_config(
    sub_key: str = _REG_PATH,
    required: bool = True,
) -> Dict[str, str]:
    """Read Windows Registry values into a dictionary."""
    if winreg is None:
        if required:
            raise RegistryConfigError("Windows Registry is only accessible on Windows systems.")
        return {}

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sub_key) as key:
            values: Dict[str, str] = {}
            index = 0
            while True:
                try:
                    name, value, _ = winreg.EnumValue(key, index)
                    if name:
                        values[name] = str(value)
                    index += 1
                except OSError:
                    break
            return values
    except OSError as exc:
        if required:
            raise RegistryConfigError(
                f"Configuration missing in HKCU\\{sub_key}.\n"
                "Run install-tokens.ps1 before using this module."
            ) from exc
        logger.debug("Registry key HKCU\\%s unavailable: %s", sub_key, exc)
        return {}


def _find_powershell(config: Mapping[str, str]) -> str:
    """Locate executable binary for PowerShell."""
    configured = (config.get("PowerShellExe") or "").strip()
    if configured:
        expanded = _expand_path(configured)
        if expanded.is_file():
            return str(expanded)
        found = shutil.which(configured)
        if found:
            return found
        raise TokenError(f"Configured PowerShellExe was not found: {configured}")

    for candidate in ("powershell.exe", "pwsh.exe", "pwsh"):
        found = shutil.which(candidate)
        if found:
            return found

    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    fallback = Path(system_root) / r"System32\WindowsPowerShell\v1.0\powershell.exe"
    if fallback.is_file():
        return str(fallback)

    raise TokenError("Could not locate powershell.exe or pwsh binary.")


class HadoopTokenManager(AbstractContextManager["HadoopTokenManager"]):
    """Manages the lifecycle of temporary Hadoop session tokens."""

    def __init__(
        self,
        config: Optional[Mapping[str, str]] = None,
        timeout: float = _DEFAULT_TIMEOUT,
    ) -> None:
        self.config = config if config is not None else get_registry_config()
        self.timeout = timeout
        self.token_path: Optional[Path] = None

        self._temp_dir: Optional[tempfile.TemporaryDirectory[str]] = None
        self._old_token_env: Optional[str] = None
        self._env_changed: bool = False

    @property
    def active(self) -> bool:
        """Check if active token file exists."""
        return self.token_path is not None and self.token_path.is_file()

    def generate_token(self, timeout: Optional[float] = None) -> Path:
        """Execute script to generate disposable token."""
        if self.active and self.token_path is not None:
            return self.token_path

        tools_raw = (self.config.get("ToolsPath") or "").strip()
        if not tools_raw:
            raise TokenError(f"ToolsPath missing in registry HKCU\\{_REG_PATH}.")

        ps_script = _expand_path(tools_raw) / "refresh-tokens.ps1"
        if not ps_script.is_file():
            raise FileNotFoundError(f"Token refresh script missing at: {ps_script}")

        if self._temp_dir is None:
            self._temp_dir = tempfile.TemporaryDirectory(prefix="hadoop-token-")

        token_file = Path(self._temp_dir.name) / f"hadoop-{os.getpid()}.dt"
        token_file.unlink(missing_ok=True)

        cmd = [
            _find_powershell(self.config),
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy", "Bypass",
            "-File", str(ps_script),
            "-Out", str(token_file),
            "-Quiet",
        ]

        run_kwargs: Dict[str, Any] = {
            "capture_output": True,
            "text": True,
            "encoding": "utf-8",
            "errors": "replace",
            "check": False,
            "timeout": timeout if timeout is not None else self.timeout,
        }

        if os.name == "nt" and hasattr(subprocess, "CREATE_NO_WINDOW"):
            run_kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW

        try:
            result = subprocess.run(cmd, **run_kwargs)
        except subprocess.TimeoutExpired as exc:
            raise TokenError(f"Token script execution timed out: {ps_script}") from exc
        except OSError as exc:
            raise TokenError(f"Failed executing token script: {exc}") from exc

        if result.returncode != 0 or not token_file.is_file():
            tail_err = result.stderr.strip()[-1000:] if result.stderr else ""
            raise TokenError(f"Token generation failed (code {result.returncode}): {tail_err}")

        try:
            os.chmod(token_file, 0o600)
        except OSError:
            logger.debug("Permissions restriction failed on %s", token_file, exc_info=True)

        self._old_token_env = os.environ.get(_TOKEN_ENV_VAR)
        os.environ[_TOKEN_ENV_VAR] = str(token_file)
        self._env_changed = True
        self.token_path = token_file

        return token_file

    def cleanup(self) -> None:
        """Revert environment variables and delete token directory."""
        if self._env_changed:
            if self._old_token_env is None:
                os.environ.pop(_TOKEN_ENV_VAR, None)
            else:
                os.environ[_TOKEN_ENV_VAR] = self._old_token_env
            self._env_changed = False

        if self._temp_dir is not None:
            try:
                self._temp_dir.cleanup()
            except OSError:
                logger.debug("Cleanup failed for %s", self._temp_dir.name, exc_info=True)
            self._temp_dir = None

        self.token_path = None

    def __enter__(self) -> HadoopTokenManager:
        self.generate_token()
        return self

    def __exit__(self, exc_type: Any, exc_val: Any, exc_tb: Any) -> None:
        self.cleanup()


def get_spark(
    conf: Optional[Mapping[str, Any]] = None,
    master: str = "yarn",
    app_name: str = "python",
    driver_port: Optional[int] = None,
    token_manager: Optional[HadoopTokenManager] = None,
    config: Optional[Mapping[str, str]] = None,
    token_timeout: Optional[float] = None,
) -> SparkSession:
    """Build and initialize a SparkSession configured for target runtime environment."""
    cfg = config if config is not None else get_registry_config(required=(master == "yarn"))

    if "SparkHome" in cfg:
        os.environ["SPARK_HOME"] = str(_expand_path(cfg["SparkHome"]))
    if "HadoopConf" in cfg:
        os.environ["HADOOP_CONF_DIR"] = str(_expand_path(cfg["HadoopConf"]))

    if master == "yarn" and (token_manager is None or not token_manager.active):
        raise TokenError(
            "YARN master requires an active HadoopTokenManager instance. "
            "Use the `spark_session()` context manager instead of calling `get_spark()`."
        )

    # Lazy import of heavy PySpark dependency
    from pyspark.sql import SparkSession

    builder = SparkSession.builder.master(master).appName(app_name)

    base_conf: Dict[str, str] = {
        "spark.security.credentials.hadoopfs.enabled": "false",
        "spark.security.credentials.hive.enabled": "false",
        "spark.security.credentials.hbase.enabled": "false",
    }

    if master == "yarn":
        staging_root = cfg.get("StagingDir") or "/tmp"
        staging_dir = _expand_path(staging_root) / _safe_username()
        base_conf["spark.yarn.stagingDir"] = staging_dir.as_posix()

    port_raw = driver_port or cfg.get("DriverPort")
    if port_raw is not None:
        port = _validate_port(port_raw, "driver_port")
        base_conf["spark.driver.port"] = str(port)
        if port == 0:
            base_conf["spark.driver.blockManager.port"] = "0"
        else:
            block_port = port + _BLOCK_MANAGER_PORT_OFFSET
            if block_port > 65535:
                raise ValueError(f"Driver port offset overflow: {block_port}")
            base_conf["spark.driver.blockManager.port"] = str(block_port)

    for k, v in base_conf.items():
        builder = builder.config(k, v)

    if conf:
        for k, v in conf.items():
            builder = builder.config(k, str(v))

    return builder.getOrCreate()


@contextmanager
def spark_session(
    conf: Optional[Mapping[str, Any]] = None,
    master: str = "yarn",
    app_name: str = "python",
    driver_port: Optional[int] = None,
    config: Optional[Mapping[str, str]] = None,
    token_timeout: Optional[float] = None,
) -> Generator[SparkSession, None, None]:
    """Context manager for SparkSession ensuring clean teardown of session and tokens."""
    cfg = config if config is not None else get_registry_config(required=(master == "yarn"))

    token_mgr: Optional[HadoopTokenManager] = None
    if master == "yarn":
        token_mgr = HadoopTokenManager(
            cfg,
            timeout=token_timeout if token_timeout is not None else _DEFAULT_TIMEOUT,
        )
        token_mgr.generate_token()

    spark: Optional[SparkSession] = None
    try:
        spark = get_spark(
            conf=conf,
            master=master,
            app_name=app_name,
            driver_port=driver_port,
            token_manager=token_mgr,
            config=cfg,
            token_timeout=token_timeout,
        )
        yield spark
    finally:
        if spark is not None:
            try:
                spark.stop()
            except Exception:
                logger.exception("SparkSession shutdown encountered an error.")

        if token_mgr is not None:
            token_mgr.cleanup()