#!/usr/bin/env python3
"""
ACO Weekly Enrollment Report - Transfer Automation

Purpose
-------
1. Connect to the SAS Linux server using the existing SSH private key.
2. Retry both the short and fully-qualified lap09 host names to tolerate
   temporary Windows DNS/name-resolution failures.
3. Verify matching REGXSA and SASQA files exist, are non-zero, and have
   stable sizes before transfer.
4. Download both files from Linux to a LOCAL Windows staging folder first.
5. Verify the local staged file sizes against the Linux source sizes.
6. Copy the verified staged files to the dated shared Z: drive folder.
7. Verify the shared-drive file sizes before considering the transfer complete.
8. Write a detailed log.

IMPORTANT
---------
The large REGXSA workbook is NOT downloaded directly to Z:.  Direct SCP to
the mapped network drive previously failed partway through the ~615 MB file
and left an incomplete workbook.  This version stages locally first, then
publishes the fully verified file to Z: using a temporary .partial name.

This script performs the Linux-to-Windows transfer portion only.
The master PowerShell controller handles formatting, QC, publishing,
and distribution.
"""

from __future__ import annotations

import argparse
import datetime as dt
import logging
import re
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

SERVER_CANDIDATES = [
    "dph-pr-sgn-lap09",
    "dph-pr-sgn-lap09.cs.govt.state.ma.us",
]

USER = "tkray"
REMOTE_DIR = "/sas_mass_health/shared/output/ACOWeeklyReport"
KEY_PATH = Path.home() / ".ssh" / "aco_linux_transfer"

DEST_ROOT = Path(r"Z:\Analytics\Rouba\Enrollment and switcher report")

# Local staging avoids direct SCP writes to the mapped Z: network drive.
STAGING_ROOT = Path.home() / "ACO_Weekly_Staging"

LOG_DIR = Path.home() / "OneDrive - Commonwealth of Massachusetts" / "Ad Hoc"
LOG_FILE = LOG_DIR / "ACO_Weekly_Transfer.log"

DEFAULT_WAIT_MINUTES = 90
DEFAULT_RETRY_SECONDS = 300

# Connection retry behavior for transient DNS/SSH failures.
HOST_RETRY_ROUNDS = 4
HOST_RETRY_SECONDS = 15

# Shared-drive publishing retry behavior.
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


def run_command(
    command: list[str],
    *,
    timeout: int | None = None,
    raise_on_error: bool = True,
) -> subprocess.CompletedProcess[str]:
    logging.debug("Running command: %s", " ".join(shlex.quote(x) for x in command))

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
        raise AutomationError(f"Command timed out: {command[0]}") from exc

    if raise_on_error and result.returncode != 0:
        stderr = (result.stderr or "").strip()
        stdout = (result.stdout or "").strip()
        detail = stderr or stdout or f"exit code {result.returncode}"
        raise AutomationError(f"Command failed: {detail}")

    return result


def ssh_raw(server: str, remote_command: str) -> subprocess.CompletedProcess[str]:
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
    """
    Try both known lap09 names multiple times.

    This avoids depending on a single DNS form while still using the validated
    lap09 automation host rather than hard-coding its current IP address.
    """
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
                logging.info("Passwordless SSH authentication succeeded via %s.", server)
                return server

            detail = (result.stderr or result.stdout or "").strip()
            if detail:
                last_error = detail
                logging.warning("SSH host %s failed: %s", server, detail)
            else:
                last_error = f"exit code {result.returncode}"
                logging.warning(
                    "SSH host %s failed with exit code %s",
                    server,
                    result.returncode,
                )

        if round_no < HOST_RETRY_ROUNDS:
            logging.info(
                "No host connected in round %s. Waiting %s seconds before retry.",
                round_no,
                HOST_RETRY_SECONDS,
            )
            time.sleep(HOST_RETRY_SECONDS)

    raise AutomationError(
        "Unable to connect to the validated lap09 SAS Linux host using either "
        f"known hostname after {HOST_RETRY_ROUNDS} retry rounds. "
        f"Last SSH error: {last_error}"
    )


def ssh_command(server: str, remote_command: str) -> str:
    result = ssh_raw(server, remote_command)
    if result.returncode != 0:
        stderr = (result.stderr or "").strip()
        stdout = (result.stdout or "").strip()
        detail = stderr or stdout or f"exit code {result.returncode}"
        raise AutomationError(f"SSH command failed on {server}: {detail}")
    return result.stdout.strip()


def remote_file_size(server: str, remote_path: str) -> int:
    output = ssh_command(server, f"stat -c %s {shlex.quote(remote_path)}")
    try:
        return int(output)
    except ValueError as exc:
        raise AutomationError(
            f"Unexpected remote size response for {remote_path}: {output!r}"
        ) from exc


def remote_file_exists(server: str, remote_path: str) -> bool:
    result = ssh_raw(server, f"test -f {shlex.quote(remote_path)}")
    return result.returncode == 0


def wait_for_remote_files(
    server: str,
    reg_remote: str,
    qc_remote: str,
    *,
    wait_minutes: int,
    retry_seconds: int,
) -> tuple[int, int]:
    deadline = time.monotonic() + wait_minutes * 60
    last_sizes: tuple[int, int] | None = None

    while True:
        reg_exists = remote_file_exists(server, reg_remote)
        qc_exists = remote_file_exists(server, qc_remote)

        if reg_exists and qc_exists:
            reg_size = remote_file_size(server, reg_remote)
            qc_size = remote_file_size(server, qc_remote)

            logging.info("Remote REGXSA size: %s bytes", f"{reg_size:,}")
            logging.info("Remote SASQA size:  %s bytes", f"{qc_size:,}")

            if reg_size > 0 and qc_size > 0:
                current_sizes = (reg_size, qc_size)

                # Require identical sizes on two checks so we do not copy while
                # SAS is still writing either workbook.
                if last_sizes == current_sizes:
                    logging.info("Remote file sizes are stable. Transfer can begin.")
                    return current_sizes

                last_sizes = current_sizes
                logging.info(
                    "Files exist and are non-zero. Waiting %s seconds to confirm "
                    "sizes are stable.",
                    retry_seconds,
                )
            else:
                logging.info("One or both files are still zero bytes. Waiting.")
        else:
            missing = []
            if not reg_exists:
                missing.append("REGXSA")
            if not qc_exists:
                missing.append("SASQA")
            logging.info("Waiting for remote file(s): %s", ", ".join(missing))

        if time.monotonic() >= deadline:
            raise AutomationError(
                f"Timed out after {wait_minutes} minutes waiting for completed report files."
            )

        time.sleep(retry_seconds)


def ensure_free_space(folder: Path, required_bytes: int) -> None:
    """
    Confirm the local staging drive has enough room for the files plus a
    reasonable safety margin.
    """
    folder.mkdir(parents=True, exist_ok=True)
    usage = shutil.disk_usage(folder)

    # Require at least 25% extra room or 500 MB, whichever is larger.
    safety_margin = max(int(required_bytes * 0.25), 500 * 1024 * 1024)
    needed = required_bytes + safety_margin

    if usage.free < needed:
        raise AutomationError(
            "Not enough free space for local staging. "
            f"Required approximately {needed:,} bytes including safety margin; "
            f"available {usage.free:,} bytes on {folder}."
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
    """
    Download one Linux file to the local Windows staging directory and verify
    that its size exactly matches the Linux source.
    """
    staging_dir.mkdir(parents=True, exist_ok=True)
    local_path = staging_dir / Path(remote_path).name

    if local_path.exists():
        logging.info("Removing previous staged file: %s", local_path)
        local_path.unlink()

    logging.info(
        "Downloading %s from %s to LOCAL staging: %s",
        Path(remote_path).name,
        server,
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
            f"SCP download to local staging failed from {server}: {detail}"
        )

    if not local_path.exists():
        raise AutomationError(
            f"Download command completed but staged file is missing: {local_path}"
        )

    actual_size = local_path.stat().st_size

    if actual_size != expected_size:
        try:
            local_path.unlink()
        except OSError:
            pass
        raise AutomationError(
            f"Staged file size mismatch for {local_path.name}: "
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
    """
    Copy a fully verified local staged file to the shared drive.

    The copy is first written as <filename>.partial.  Only after the copied
    file size is verified is it renamed to the real filename.  This prevents
    an interrupted network copy from leaving an incomplete report that looks
    finished.
    """
    destination_dir.mkdir(parents=True, exist_ok=True)

    final_path = destination_dir / staged_file.name
    partial_path = destination_dir / f"{staged_file.name}.partial"

    for attempt in range(1, PUBLISH_RETRY_ATTEMPTS + 1):
        try:
            if partial_path.exists():
                partial_path.unlink()

            # Remove an old/incomplete final file before publishing the new one.
            if final_path.exists():
                logging.info("Removing previous destination file: %s", final_path)
                final_path.unlink()

            logging.info(
                "Publishing %s to shared drive (attempt %s of %s)",
                staged_file.name,
                attempt,
                PUBLISH_RETRY_ATTEMPTS,
            )

            shutil.copyfile(staged_file, partial_path)

            partial_size = partial_path.stat().st_size
            if partial_size != expected_size:
                raise AutomationError(
                    f"Shared-drive temporary copy size mismatch for {staged_file.name}: "
                    f"expected={expected_size:,}, copied={partial_size:,}"
                )

            # Rename only after size verification.
            partial_path.replace(final_path)

            final_size = final_path.stat().st_size
            if final_size != expected_size:
                raise AutomationError(
                    f"Shared-drive final file size mismatch for {staged_file.name}: "
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
                    f"Unable to publish {staged_file.name} to the shared drive "
                    f"after {PUBLISH_RETRY_ATTEMPTS} attempts: {exc}"
                ) from exc

            logging.info(
                "Waiting %s seconds before shared-drive retry.",
                PUBLISH_RETRY_SECONDS,
            )
            time.sleep(PUBLISH_RETRY_SECONDS)

    raise AutomationError(f"Unexpected publish failure for {staged_file.name}")


def cleanup_staging(staging_dir: Path) -> None:
    """
    Remove successfully published staged report files and then remove the
    report-date staging folder if it is empty.
    """
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

        logging.info("Local staging cleanup completed: %s", staging_dir)

    except OSError as exc:
        # Cleanup failure should not turn an otherwise successful report into
        # a failed production run.
        logging.warning("Could not fully clean local staging folder: %s", exc)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Download the ACO Weekly REGXSA and SASQA files from SAS Linux."
    )
    parser.add_argument(
        "--report-date",
        help="Report date in YYYYMMDD format. Default: today's date.",
    )
    parser.add_argument(
        "--wait-minutes",
        type=int,
        default=DEFAULT_WAIT_MINUTES,
        help=f"Maximum wait for completed files. Default: {DEFAULT_WAIT_MINUTES}.",
    )
    parser.add_argument(
        "--retry-seconds",
        type=int,
        default=DEFAULT_RETRY_SECONDS,
        help=f"Seconds between completion checks. Default: {DEFAULT_RETRY_SECONDS}.",
    )
    return parser.parse_args()


def validate_report_date(value: str) -> str:
    if not re.fullmatch(r"\d{8}", value):
        raise AutomationError("Report date must be exactly 8 digits in YYYYMMDD format.")

    try:
        dt.datetime.strptime(value, "%Y%m%d")
    except ValueError as exc:
        raise AutomationError(f"Invalid report date: {value}") from exc

    return value


def destination_folder_name(report_date: str) -> str:
    parsed = dt.datetime.strptime(report_date, "%Y%m%d")
    return f"Enrollment Report {parsed.month}-{parsed.day}-{parsed.year}"


def main() -> int:
    configure_logging()
    args = parse_args()

    report_date = validate_report_date(
        args.report_date or dt.date.today().strftime("%Y%m%d")
    )

    reg_name = f"ReportTestMonthly-{report_date}_REGXSA.xls"
    qc_name = f"ReportTestMonthly-{report_date}_SASQA.xls"

    reg_remote = f"{REMOTE_DIR}/{reg_name}"
    qc_remote = f"{REMOTE_DIR}/{qc_name}"

    destination = DEST_ROOT / destination_folder_name(report_date)
    staging_dir = STAGING_ROOT / report_date

    logging.info("=" * 72)
    logging.info("ACO Weekly transfer started")
    logging.info("Report date: %s", report_date)
    logging.info("Host candidates: %s", ", ".join(SERVER_CANDIDATES))
    logging.info("Local staging: %s", staging_dir)
    logging.info("Destination: %s", destination)

    try:
        if not KEY_PATH.exists():
            raise AutomationError(f"SSH private key not found: {KEY_PATH}")

        if not DEST_ROOT.exists():
            raise AutomationError(
                f"Shared destination root is not available: {DEST_ROOT}. "
                "Confirm the Z: drive is connected."
            )

        server = select_working_server()
        logging.info("Selected SAS Linux host: %s", server)

        reg_remote_size, qc_remote_size = wait_for_remote_files(
            server,
            reg_remote,
            qc_remote,
            wait_minutes=args.wait_minutes,
            retry_seconds=args.retry_seconds,
        )

        total_remote_size = reg_remote_size + qc_remote_size
        ensure_free_space(staging_dir, total_remote_size)

        # STEP A: Download and verify both files locally.
        reg_staged = scp_download_to_staging(
            server,
            reg_remote,
            staging_dir,
            reg_remote_size,
        )

        qc_staged = scp_download_to_staging(
            server,
            qc_remote,
            staging_dir,
            qc_remote_size,
        )

        logging.info("Both Linux files are fully verified in local staging.")

        # STEP B: Publish verified local files to the shared drive.
        reg_final = publish_to_shared_drive(
            reg_staged,
            destination,
            reg_remote_size,
        )

        qc_final = publish_to_shared_drive(
            qc_staged,
            destination,
            qc_remote_size,
        )

        # Final verification of both production destination files.
        reg_final_size = reg_final.stat().st_size
        qc_final_size = qc_final.stat().st_size

        if reg_final_size != reg_remote_size:
            raise AutomationError(
                f"Final REGXSA size mismatch: remote={reg_remote_size:,}, "
                f"shared={reg_final_size:,}"
            )

        if qc_final_size != qc_remote_size:
            raise AutomationError(
                f"Final SASQA size mismatch: remote={qc_remote_size:,}, "
                f"shared={qc_final_size:,}"
            )

        logging.info("REGXSA verified on shared drive: %s bytes", f"{reg_final_size:,}")
        logging.info("SASQA verified on shared drive:  %s bytes", f"{qc_final_size:,}")

        cleanup_staging(staging_dir)

        logging.info("ACO Weekly transfer completed successfully.")
        logging.info("=" * 72)
        return 0

    except AutomationError as exc:
        logging.error("ACO Weekly transfer failed: %s", exc)
        logging.info(
            "Any fully downloaded local staged files are being preserved for troubleshooting."
        )
        logging.info("=" * 72)
        return 1

    except Exception:
        logging.exception("Unexpected fatal error")
        logging.info(
            "Any fully downloaded local staged files are being preserved for troubleshooting."
        )
        logging.info("=" * 72)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
