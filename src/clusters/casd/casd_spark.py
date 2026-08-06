import atexit
import logging
import os
import shutil
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import TYPE_CHECKING, Any, Dict, Generator, Optional

if TYPE_CHECKING:
    from pyspark.sql import SparkSession

try:
    import winreg
except ImportError:  # Non-Windows environments
    winreg = None


logger = logging.getLogger(__name__)

_REG_PATH: str = r"Software\CASD\Hadoop"
_TOKEN_ENV_VAR: str = "HADOOP_TOKEN_FILE_LOCATION"
_DEFAULT_TIMEOUT: float = 120.0
_BLOCK_MANAGER_PORT_OFFSET: int = 200


class RegistryConfigError(RuntimeError):
    """Raised when required registry configuration is missing or unreadable."""


class TokenError(RuntimeError):
    """Raised when a Hadoop session token cannot be created."""


def _tail(text: Optional[str], limit: int = 2000) -> str:
    """Return the end of potentially long subprocess output."""
    if not text:
        return ""

    text = text.strip()
    return text if len(text) <= limit else f"...{text[-limit:]}"


def _expand_path(value: str) -> str:
    """Expand environment variables and user home in paths."""
    return os.path.expandvars(os.path.expanduser(value))


def _safe_username() -> str:
    """Return a filesystem-safe username for staging paths."""
    name = os.environ.get("USERNAME") or os.environ.get("USER") or "default"
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in name)


def _to_port(value: Any, field_name: str) -> int:
    """Validate and convert a port value."""
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(
            f"{field_name} must be an integer port, got: {value!r}"
        ) from exc

    if not 0 <= port <= 65535:
        raise ValueError(
            f"{field_name} must be between 0 and 65535, got: {port}"
        )

    return port


def get_registry_config(
    sub_key: str = _REG_PATH,
    required: bool = True,
) -> Dict[str, str]:
    """
    Read Windows Registry values into a dictionary.

    If required=False, missing registry keys return an empty dictionary
    instead of raising.
    """
    if winreg is None:
        if required:
            raise RegistryConfigError(
                "Windows Registry configuration is only available on Windows."
            )
        return {}

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sub_key) as key:
            values: Dict[str, str] = {}
            index = 0

            while True:
                try:
                    name, value, _ = winreg.EnumValue(key, index)
                except OSError:
                    break

                # Skip the unnamed default value unless you intentionally use it.
                if name:
                    values[name] = str(value)

                index += 1

            return values

    except OSError as exc:
        if required:
            raise RegistryConfigError(
                f"Configuration missing in HKCU\\{sub_key}.\n"
                "Run install-tokens.ps1 before using this module."
            ) from exc

        logger.debug("Registry key HKCU\\%s not available: %s", sub_key, exc)
        return {}


def _find_powershell(config: Dict[str, str]) -> str:
    """
    Locate PowerShell executable.

    Preference order:
    1. PowerShellExe value from registry/config.
    2. powershell.exe on PATH.
    3. pwsh.exe/pwsh on PATH.
    4. Default Windows PowerShell location.
    """
    configured = (config.get("PowerShellExe") or "").strip()

    if configured:
        configured = _expand_path(configured)

        found = shutil.which(configured)
        if found:
            return found

        candidate = Path(configured)
        if candidate.is_file():
            return str(candidate)

        raise TokenError(
            f"Configured PowerShellExe was not found: {configured}"
        )

    for candidate in ("powershell.exe", "pwsh.exe", "pwsh"):
        found = shutil.which(candidate)
        if found:
            return found

    system_root = os.environ.get("SystemRoot", r"C:\Windows")
    fallback = Path(system_root) / r"System32\WindowsPowerShell\v1.0\powershell.exe"

    if fallback.is_file():
        return str(fallback)

    raise TokenError("Could not locate powershell.exe or pwsh.")


class HadoopTokenManager:
    """
    Manages the disposable Hadoop session token lifecycle.

    The token is placed in a private temporary directory and removed
    during cleanup.
    """

    def __init__(
        self,
        config: Optional[Dict[str, str]] = None,
        timeout: float = _DEFAULT_TIMEOUT,
    ) -> None:
        self.config = config if config is not None else get_registry_config()
        self.timeout = timeout
        self.token_path: Optional[Path] = None

        self._temp_dir: Optional[tempfile.TemporaryDirectory] = None
        self._old_token_env: Optional[str] = None
        self._env_changed = False

    @property
    def active(self) -> bool:
        """Return True if a token file currently exists."""
        return self.token_path is not None and self.token_path.is_file()

    def generate_token(self, timeout: Optional[float] = None) -> Path:
        """
        Generate a Hadoop session token using the PowerShell script.

        Returns the path to the generated token file.
        """
        if self.active and self.token_path is not None:
            return self.token_path

        tools_raw = (self.config.get("ToolsPath") or "").strip()
        if not tools_raw:
            raise TokenError(
                f"ToolsPath is missing in HKCU\\{_REG_PATH}. "
                "Run install-tokens.ps1 or repair the registry configuration."
            )

        ps_script = Path(_expand_path(tools_raw)) / "refresh-tokens.ps1"

        if not ps_script.is_file():
            raise FileNotFoundError(
                f"Token refresh script missing at: {ps_script}"
            )

        if self._temp_dir is None:
            self._temp_dir = tempfile.TemporaryDirectory(prefix="hadoop-token-")

        token_file = Path(self._temp_dir.name) / f"hadoop-{os.getpid()}.dt"

        # Avoid stale token files causing false success.
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
            raise TokenError(
                f"Token script timed out after {run_kwargs['timeout']} seconds: {ps_script}"
            ) from exc
        except OSError as exc:
            raise TokenError(
                f"Could not execute token script {ps_script}: {exc}"
            ) from exc

        if result.returncode != 0 or not token_file.is_file():
            raise TokenError(
                "Failed to generate Hadoop session token.\n"
                f"Command: {subprocess.list2cmdline(cmd)}\n"
                f"Return code: {result.returncode}\n"
                f"stdout: {_tail(result.stdout)}\n"
                f"stderr: {_tail(result.stderr)}"
            )

        try:
            # Best-effort permission hardening. On Windows this has limited effect.
            os.chmod(token_file, 0o600)
        except OSError:
            logger.debug(
                "Could not set restrictive permissions on %s",
                token_file,
                exc_info=True,
            )

        self._old_token_env = os.environ.get(_TOKEN_ENV_VAR)
        os.environ[_TOKEN_ENV_VAR] = str(token_file)
        self._env_changed = True
        self.token_path = token_file

        return token_file

    def cleanup(self) -> None:
        """
        Remove token artifacts and restore the previous environment variable.
        """
        if self._env_changed:
            if self._old_token_env is None:
                os.environ.pop(_TOKEN_ENV_VAR, None)
            else:
                os.environ[_TOKEN_ENV_VAR] = self._old_token_env

            self._env_changed = False

        self._old_token_env = None

        if self._temp_dir is not None:
            try:
                self._temp_dir.cleanup()
            except OSError:
                logger.debug(
                    "Could not fully remove temporary token directory %s",
                    getattr(self._temp_dir, "name", "<unknown>"),
                    exc_info=True,
                )

            self._temp_dir = None

        self.token_path = None

    def __enter__(self) -> "HadoopTokenManager":
        self.generate_token()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb) -> bool:
        self.cleanup()
        return False


def get_spark(
    conf: Optional[Dict[str, Any]] = None,
    master: str = "yarn",
    app_name: str = "python",
    driver_port: Optional[int] = None,
    token_manager: Optional[HadoopTokenManager] = None,
    config: Optional[Dict[str, str]] = None,
    token_timeout: Optional[float] = None,
) -> SparkSession:
    """
    Initialize and return a SparkSession configured for the target environment.

    If master='yarn' and no token_manager is supplied, a token manager is created.
    For predictable cleanup, prefer spark_session() over calling get_spark() directly.
    """
    cfg = (
        config
        if config is not None
        else get_registry_config(required=(master == "yarn"))
    )

    spark_home = cfg.get("SparkHome")
    if spark_home:
        os.environ["SPARK_HOME"] = _expand_path(spark_home)

    hadoop_conf = cfg.get("HadoopConf")
    if hadoop_conf:
        os.environ["HADOOP_CONF_DIR"] = _expand_path(hadoop_conf)

    mgr: Optional[HadoopTokenManager] = None
    owns_token_manager = False

    if master == "yarn":
        if token_manager is None:
            mgr = HadoopTokenManager(
                cfg,
                timeout=token_timeout if token_timeout is not None else _DEFAULT_TIMEOUT,
            )
            owns_token_manager = True
        else:
            mgr = token_manager

        if not mgr.active:
            mgr.generate_token()

    try:
        builder = SparkSession.builder.master(master).appName(app_name)

        # Internal/base settings are applied first so user-provided conf can override them.
        base_conf: Dict[str, Any] = {
            "spark.security.credentials.hadoopfs.enabled": "false",
            "spark.security.credentials.hive.enabled": "false",
            "spark.security.credentials.hbase.enabled": "false",
        }

        if master == "yarn":
            staging_root = cfg.get("StagingDir") or "/tmp"
            staging_dir = Path(_expand_path(staging_root)) / _safe_username()
            base_conf["spark.yarn.stagingDir"] = staging_dir.as_posix()

        port_source: Any = driver_port

        if port_source is None and cfg.get("DriverPort"):
            port_source = cfg.get("DriverPort")

        if port_source is not None:
            port = _to_port(port_source, "driver_port")
            base_conf["spark.driver.port"] = str(port)

            if port == 0:
                base_conf["spark.driver.blockManager.port"] = "0"
            else:
                block_port = port + _BLOCK_MANAGER_PORT_OFFSET

                if block_port > 65535:
                    raise ValueError(
                        "driver_port is too large for the block-manager offset. "
                        f"driver_port={port}, offset={_BLOCK_MANAGER_PORT_OFFSET}."
                    )

                base_conf["spark.driver.blockManager.port"] = str(block_port)

        for key, value in base_conf.items():
            builder = builder.config(key, str(value))

        if conf:
            for key, value in conf.items():
                builder = builder.config(key, str(value))

        spark = builder.getOrCreate()

    except Exception:
        if owns_token_manager and mgr is not None:
            mgr.cleanup()
        raise

    if owns_token_manager and mgr is not None:
        # Best-effort cleanup for callers that use get_spark() directly.
        atexit.register(mgr.cleanup)

    return spark


@contextmanager
def spark_session(
    conf: Optional[Dict[str, Any]] = None,
    master: str = "yarn",
    app_name: str = "python",
    driver_port: Optional[int] = None,
    config: Optional[Dict[str, str]] = None,
    token_timeout: Optional[float] = None,
) -> Generator[SparkSession, None, None]:
    """
    Context manager for SparkSession that ensures proper cleanup.

    This guarantees that:
    - SparkSession.stop() is attempted.
    - Temporary token files are removed.
    - HADOOP_TOKEN_FILE_LOCATION is restored.
    """
    cfg = (
        config
        if config is not None
        else get_registry_config(required=(master == "yarn"))
    )

    token_mgr: Optional[HadoopTokenManager] = None

    if master == "yarn":
        token_mgr = HadoopTokenManager(
            cfg,
            timeout=token_timeout if token_timeout is not None else _DEFAULT_TIMEOUT,
        )

    spark: Optional[SparkSession] = None

    try:
        if token_mgr is not None:
            token_mgr.generate_token()

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
            except Exception as e:
                logger.exception(f"Failed to stop SparkSession cleanly. {e}")

        if token_mgr is not None:
            token_mgr.cleanup()