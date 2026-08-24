#!/usr/bin/env python3
"""
Monthly Advocacy Report - Transfer Automation v1

Purpose
-------
1. Determine the prior calendar reporting month automatically.
2. Connect to the SAS Linux server using the existing SSH private key.
3. Require the Monthly Advocacy SUCCESS flag created by the SAS wrapper.
4. Verify the expected final Advocacy report files exist and are non-zero.
5. Require stable remote file sizes before transfer.
6. Download all final report files from Linux to a LOCAL Windows staging folder.
7. Verify staged file sizes against the Linux source sizes.
8. Publish the verified files to the permanent Advocate report shared folder.
9. Verify destination file sizes.
10. Clean local staging after a successful transfer.
11. Write a detailed transfer log.

This script does NOT run SAS.  It transfers only a successfully completed
Monthly Advocacy report.
"""

from __future__ import annotations

import datetime as dt
import logging
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path


# =============================================================================
# Production connection settings
# =============================================================================

SERVER_CANDIDATES = [
    "dph-pr-sgn-lap09",
    "dph-pr-sgn-lap09.cs.govt.state.ma.us",
]

USER = "tkray"

KEY_PATH = Path.home() / ".ssh" / "aco_linux_transfer"

REMOTE_BASE = "/sas_mass_health/shared/Advocacy_Dynamic"
REMOTE_OUTPUT_ROOT = f"{REMOTE_BASE}/Output"
REMOTE_QC_ROOT = f"{REMOTE_BASE}/QC"


# =============================================================================
# Windows production settings
# =============================================================================

DEST_ROOT = Path(
    r"\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St"
    r"\File Services\Adhoc\JF\Budget\Enrollments & Advocacy\Advocate report"
)

STAGING_ROOT = Path.home() / "Advocacy_Monthly_Staging"

LOG_DIR = (
    Path.home()
    / "OneDrive - Commonwealth of Massachusetts"
    / "Ad Hoc"
)

LOG_FILE = LOG_DIR / "Advocacy_Monthly_Transfer.log"


# =============================================================================
# Retry / stability settings
# =============================================================================

HOST_RETRY_ROUNDS = 4
HOST_RETRY_SECONDS = 15

STABILITY_WAIT_SECONDS = 30

PUBLISH_RETRY_ATTEMPTS = 3
PUBLISH_RETRY_SECONDS = 15


class AutomationError(RuntimeError):
    """Raised when a required automation step fails."""


def configure_logging() -> None:
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
        handlers=[
            logging.FileHandler(LOG_FILE, encoding="utf-8"),
            logging.StreamHandler(sys.stdout),
        ],
    )


def prior_reporting_month(today: dt.date | None = None) -> tuple[int, int]:
    """Return the prior calendar month as (year, month)."""

    today = today or dt.date.today()

    if today.month == 1:
        return today.year - 1, 12

    return today.year, today.month - 1


def reporting_values() -> dict[str, str]:
    """
    Build all dynamic reporting values.

    Example for a September 2026 run:
        YYYYMM       = 202608
        MM_YYYY      = 08_2026
        MONTH_TEXT   = aug
        MONTH_NAME   = August
        YYYYMMDD_END = 20260831
    """

    year, month = prior_reporting_month()
    month_end = (
        dt.date(year + 1, 1, 1) - dt.timedelta(days=1)
        if month == 12
        else dt.date(year, month + 1, 1) - dt.timedelta(days=1)
    )

    return {
        "YYYYMM": f"{year}{month:02d}",
        "MM_YYYY": f"{month:02d}_{year}",
        "MONTH_TEXT": month_end.strftime("%b").lower(),
        "MONTH_NAME": month_end.strftime("%B"),
        "YYYYMMDD_END": month_end.strftime("%Y%m%d"),
    }


def expected_filenames(values: dict[str, str]) -> list[str]:
    """
    Final monthly deliverables validated in the July 2026 Advocacy run.

    .bak, TEST, QC, and development files are intentionally excluded.
    """

    yyyymm = values["YYYYMM"]
    mon = values["MONTH_TEXT"]
    year = yyyymm[:4]
    yyyymmdd_end = values["YYYYMMDD_END"]

    return [
        f"caseload_with_adds_and_terms_{yyyymm}_v3.csv",
        f"caseload_with_adds_and_terms_by_BGs_{yyyymm}_v1.xlsx",
        f"caseload_with_adds_and_terms_by_reopens_{yyyymm}v10.xlsx",
        f"caseload_with_adds_and_terms_by_reopens_{yyyymm}wbgorigv5.xlsx",
        f"new_eligibility - {mon} {year} w agency.xlsx",
        f"new_eligibility - {mon} {year} w bg.xlsx",
        f"new_terminations - by BG {yyyymm}.xlsx",
        f"new_terminations - option1 wtieout {yyyymm}.xlsx",
        f"Snapshot - {yyyymmdd_end}mf.csv",
    ]


def run_command(
    command: list[str],
    *,
    timeout: int | None = None,
    raise_on_error: bool = True,
) -> subprocess.CompletedProcess[str]:

    try:
        result = subprocess.run(
            command,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError as exc:
        raise AutomationError(
            f"Required command was not found: {command[0]}. "
            "Confirm Windows OpenSSH Client is installed."
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise AutomationError(
            f"Command timed out: {command[0]}"
        ) from exc

    if raise_on_error and result.returncode != 0:
        stderr = (result.stderr or "").strip()
        stdout = (result.stdout or "").strip()
        detail = stderr or stdout or f"exit code {result.returncode}"
        raise AutomationError(f"Command failed: {detail}")

    return result


def ssh_raw(
    server: str,
    remote_command: str,
) -> subprocess.CompletedProcess[str]:

    return run_command(
        [
            "ssh",
            "-i",
            str(KEY_PATH),
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=30",
            f"{USER}@{server}",
            remote_command,
        ],
        timeout=60,
        raise_on_error=False,
    )


def select_working_server() -> str:
    """Try both validated lap09 names with retry handling."""

    last_error = ""

    for round_no in range(1, HOST_RETRY_ROUNDS + 1):
        for server in SERVER_CANDIDATES:

            logging.info(
                "Testing SSH host %s (attempt round %s of %s)",
                server,
                round_no,
                HOST_RETRY_ROUNDS,
            )

            result = ssh_raw(server, "whoami")

            if result.returncode == 0 and result.stdout.strip() == USER:
                logging.info(
                    "Passwordless SSH authentication succeeded via %s.",
                    server,
                )
                return server

            detail = (result.stderr or result.stdout or "").strip()

            if detail:
                last_error = detail
                logging.warning(
                    "SSH host %s failed: %s",
                    server,
                    detail,
                )

        if round_no < HOST_RETRY_ROUNDS:
            logging.info(
                "No host connected in round %s. Waiting %s seconds.",
                round_no,
                HOST_RETRY_SECONDS,
            )
            time.sleep(HOST_RETRY_SECONDS)

    raise AutomationError(
        "Unable to connect to the validated SAS Linux host. "
        f"Last SSH error: {last_error}"
    )


def ssh_command(server: str, remote_command: str) -> str:
    result = ssh_raw(server, remote_command)

    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        stdout = (result.stdout or "").strip()
        detail = stderr or stdout or f"exit code {result.returncode}"
        raise AutomationError(
            f"SSH command failed on {server}: {detail}"
        )

    return result.stdout.strip()


def remote_file_exists(server: str, remote_path: str) -> bool:
    result = ssh_raw(
        server,
        f"test -f {shlex.quote(remote_path)}",
    )
    return result.returncode == 0


def remote_file_size(server: str, remote_path: str) -> int:
    output = ssh_command(
        server,
        f"stat -c %s {shlex.quote(remote_path)}",
    )

    try:
        return int(output)
    except ValueError as exc:
        raise AutomationError(
            f"Unexpected remote size response for {remote_path}: {output!r}"
        ) from exc


def verify_success_flag(
    server: str,
    yyyymm: str,
) -> str:
    """Require the SAS wrapper's monthly SUCCESS marker."""

    flag_path = (
        f"{REMOTE_QC_ROOT}/Advocacy_Master_{yyyymm}_SUCCESS.flag"
    )

    if not remote_file_exists(server, flag_path):
        raise AutomationError(
            "Monthly Advocacy SUCCESS flag was not found. "
            f"Expected: {flag_path}. "
            "Transfer was stopped so stale/incomplete reports are not published."
        )

    flag_text = ssh_command(
        server,
        f"cat {shlex.quote(flag_path)}",
    )

    if "STATUS=SUCCESS" not in flag_text:
        raise AutomationError(
            f"Advocacy SUCCESS flag is invalid: {flag_path}"
        )

    if f"REPORT_YYYYMM={yyyymm}" not in flag_text:
        raise AutomationError(
            "Advocacy SUCCESS flag belongs to a different report month. "
            f"Expected REPORT_YYYYMM={yyyymm}."
        )

    logging.info("Monthly Advocacy SUCCESS flag verified: %s", flag_path)
    return flag_path


def get_remote_sizes(
    server: str,
    remote_dir: str,
    filenames: list[str],
) -> dict[str, int]:
    """Verify every expected report exists and is non-zero."""

    sizes: dict[str, int] = {}

    for filename in filenames:
        remote_path = f"{remote_dir}/{filename}"

        if not remote_file_exists(server, remote_path):
            raise AutomationError(
                f"Required Advocacy report is missing: {remote_path}"
            )

        size = remote_file_size(server, remote_path)

        if size <= 0:
            raise AutomationError(
                f"Required Advocacy report is zero bytes: {remote_path}"
            )

        sizes[filename] = size
        logging.info(
            "Remote file verified: %s (%s bytes)",
            filename,
            f"{size:,}",
        )

    return sizes


def verify_remote_sizes_stable(
    server: str,
    remote_dir: str,
    filenames: list[str],
) -> dict[str, int]:
    """
    Require identical non-zero sizes on two checks before transfer.
    """

    first_sizes = get_remote_sizes(
        server,
        remote_dir,
        filenames,
    )

    logging.info(
        "All expected files exist and are non-zero. "
        "Waiting %s seconds to confirm sizes are stable.",
        STABILITY_WAIT_SECONDS,
    )

    time.sleep(STABILITY_WAIT_SECONDS)

    second_sizes = get_remote_sizes(
        server,
        remote_dir,
        filenames,
    )

    if first_sizes != second_sizes:
        raise AutomationError(
            "One or more Advocacy report files changed size during the "
            "stability check. Transfer stopped because SAS may still be writing."
        )

    logging.info("All remote Advocacy report sizes are stable.")
    return second_sizes


def ensure_free_space(
    folder: Path,
    required_bytes: int,
) -> None:

    folder.mkdir(parents=True, exist_ok=True)
    usage = shutil.disk_usage(folder)

    safety_margin = max(
        int(required_bytes * 0.25),
        250 * 1024 * 1024,
    )

    needed = required_bytes + safety_margin

    if usage.free < needed:
        raise AutomationError(
            "Not enough local staging space. "
            f"Required approximately {needed:,} bytes; "
            f"available {usage.free:,} bytes."
        )

    logging.info(
        "Local staging free space check passed: %s bytes available.",
        f"{usage.free:,}",
    )


def scp_download_to_staging(
    server: str,
    remote_path: str,
    staging_dir: Path,
    expected_size: int,
) -> Path:

    staging_dir.mkdir(parents=True, exist_ok=True)
    local_path = staging_dir / Path(remote_path).name

    if local_path.exists():
        local_path.unlink()

    logging.info(
        "Downloading %s to local staging: %s",
        Path(remote_path).name,
        staging_dir,
    )

    result = run_command(
        [
            "scp",
            "-i",
            str(KEY_PATH),
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=30",
            f"{USER}@{server}:{remote_path}",
            str(staging_dir),
        ],
        timeout=7200,
        raise_on_error=False,
    )

    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()

        if local_path.exists():
            try:
                local_path.unlink()
            except OSError:
                pass

        raise AutomationError(
            f"SCP download failed for {Path(remote_path).name}: {detail}"
        )

    if not local_path.exists():
        raise AutomationError(
            f"Downloaded staged file is missing: {local_path}"
        )

    actual_size = local_path.stat().st_size

    if actual_size != expected_size:
        try:
            local_path.unlink()
        except OSError:
            pass

        raise AutomationError(
            f"Staged size mismatch for {local_path.name}: "
            f"remote={expected_size:,}, staged={actual_size:,}"
        )

    logging.info(
        "Local staged file verified: %s (%s bytes)",
        local_path.name,
        f"{actual_size:,}",
    )

    return local_path


def publish_to_shared_drive(
    staged_file: Path,
    destination_dir: Path,
    expected_size: int,
) -> Path:

    if not destination_dir.exists():
        raise AutomationError(
            f"Advocate report destination is not available: {destination_dir}"
        )

    final_path = destination_dir / staged_file.name
    partial_path = destination_dir / f"{staged_file.name}.partial"

    for attempt in range(1, PUBLISH_RETRY_ATTEMPTS + 1):
        try:
            if partial_path.exists():
                partial_path.unlink()

            if final_path.exists():
                logging.info(
                    "Removing previous destination file: %s",
                    final_path,
                )
                final_path.unlink()

            logging.info(
                "Publishing %s to Advocate report folder "
                "(attempt %s of %s)",
                staged_file.name,
                attempt,
                PUBLISH_RETRY_ATTEMPTS,
            )

            shutil.copyfile(
                staged_file,
                partial_path,
            )

            partial_size = partial_path.stat().st_size

            if partial_size != expected_size:
                raise AutomationError(
                    f"Temporary shared-drive copy size mismatch for "
                    f"{staged_file.name}: expected={expected_size:,}, "
                    f"copied={partial_size:,}"
                )

            partial_path.replace(final_path)

            final_size = final_path.stat().st_size

            if final_size != expected_size:
                raise AutomationError(
                    f"Final shared-drive size mismatch for {staged_file.name}: "
                    f"expected={expected_size:,}, final={final_size:,}"
                )

            logging.info(
                "Shared-drive file verified: %s (%s bytes)",
                final_path,
                f"{final_size:,}",
            )

            return final_path

        except Exception as exc:

            logging.warning(
                "Shared-drive publish attempt %s failed for %s: %s",
                attempt,
                staged_file.name,
                exc,
            )

            for cleanup_path in (partial_path, final_path):
                if cleanup_path.exists():
                    try:
                        cleanup_path.unlink()
                    except OSError:
                        pass

            if attempt >= PUBLISH_RETRY_ATTEMPTS:
                raise AutomationError(
                    f"Unable to publish {staged_file.name} after "
                    f"{PUBLISH_RETRY_ATTEMPTS} attempts: {exc}"
                ) from exc

            logging.info(
                "Waiting %s seconds before shared-drive retry.",
                PUBLISH_RETRY_SECONDS,
            )
            time.sleep(PUBLISH_RETRY_SECONDS)

    raise AutomationError(
        f"Unexpected publish failure for {staged_file.name}"
    )


def cleanup_staging(staging_dir: Path) -> None:

    try:
        if not staging_dir.exists():
            return

        for child in staging_dir.iterdir():
            if child.is_file():
                child.unlink()

        try:
            staging_dir.rmdir()
        except OSError:
            pass

        logging.info(
            "Local staging cleanup completed: %s",
            staging_dir,
        )

    except OSError as exc:
        logging.warning(
            "Could not fully clean local staging folder: %s",
            exc,
        )


def main() -> int:

    configure_logging()

    values = reporting_values()

    yyyymm = values["YYYYMM"]
    monthly_folder = values["MM_YYYY"]

    filenames = expected_filenames(values)

    remote_dir = (
        f"{REMOTE_OUTPUT_ROOT}/{monthly_folder}"
    )

    staging_dir = (
        STAGING_ROOT / yyyymm
    )

    logging.info("=" * 72)
    logging.info("MONTHLY ADVOCACY TRANSFER STARTED")
    logging.info("Report month: %s", yyyymm)
    logging.info("Remote source: %s", remote_dir)
    logging.info("Local staging: %s", staging_dir)
    logging.info("Destination: %s", DEST_ROOT)
    logging.info("Expected final files: %s", len(filenames))

    try:

        if not KEY_PATH.exists():
            raise AutomationError(
                f"SSH private key not found: {KEY_PATH}"
            )

        if not DEST_ROOT.exists():
            raise AutomationError(
                "Advocate report shared destination is not available: "
                f"{DEST_ROOT}"
            )

        server = select_working_server()

        logging.info(
            "Selected SAS Linux host: %s",
            server,
        )

        verify_success_flag(
            server,
            yyyymm,
        )

        remote_sizes = verify_remote_sizes_stable(
            server,
            remote_dir,
            filenames,
        )

        total_remote_size = sum(remote_sizes.values())

        ensure_free_space(
            staging_dir,
            total_remote_size,
        )

        staged_files: dict[str, Path] = {}

        for filename in filenames:

            remote_path = (
                f"{remote_dir}/{filename}"
            )

            staged_files[filename] = scp_download_to_staging(
                server,
                remote_path,
                staging_dir,
                remote_sizes[filename],
            )

        logging.info(
            "All %s Advocacy files are fully verified in local staging.",
            len(staged_files),
        )

        published_files: dict[str, Path] = {}

        for filename in filenames:

            published_files[filename] = publish_to_shared_drive(
                staged_files[filename],
                DEST_ROOT,
                remote_sizes[filename],
            )

        for filename in filenames:

            final_size = published_files[filename].stat().st_size

            if final_size != remote_sizes[filename]:
                raise AutomationError(
                    f"Final verification failed for {filename}: "
                    f"remote={remote_sizes[filename]:,}, "
                    f"shared={final_size:,}"
                )

        cleanup_staging(staging_dir)

        logging.info(
            "All %s Advocacy reports were published and verified.",
            len(filenames),
        )

        logging.info(
            "MONTHLY ADVOCACY TRANSFER COMPLETED SUCCESSFULLY."
        )

        logging.info("=" * 72)

        return 0

    except AutomationError as exc:

        logging.error(
            "MONTHLY ADVOCACY TRANSFER FAILED: %s",
            exc,
        )

        logging.info(
            "Any fully downloaded local staged files are preserved "
            "for troubleshooting."
        )

        logging.info("=" * 72)

        return 1

    except Exception:

        logging.exception(
            "Unexpected fatal error in Monthly Advocacy transfer."
        )

        logging.info(
            "Any fully downloaded local staged files are preserved "
            "for troubleshooting."
        )

        logging.info("=" * 72)

        return 1


if __name__ == "__main__":
    raise SystemExit(main())
