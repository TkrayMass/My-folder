import calendar
import sys
from datetime import date, datetime
from pathlib import Path

import win32com.client


BUDGET_FOLDER = Path(
    r"\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St"
    r"\File Services\Adhoc\JF\Budget"
)

LOG_FILE = Path(
    r"C:\Users\TKray\OneDrive - Commonwealth of Massachusetts"
    r"\Ad Hoc\Monthly_Report_Email.log"
)

RECIPIENTS = [
    "Tatyana.Kray@mass.gov",
    "Marissa.Jones@mass.gov",
    "Julia.Paolino@mass.gov",
]


def write_log(message: str) -> None:
    timestamp = datetime.now().strftime("%Y-%m-%d %I:%M:%S %p")
    log_message = f"{timestamp} | {message}"

    print(log_message)

    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)

    with LOG_FILE.open("a", encoding="utf-8") as log:
        log.write(log_message + "\n")


def previous_completed_month() -> tuple[int, int]:
    today = date.today()

    if today.month == 1:
        return today.year - 1, 12

    return today.year, today.month - 1


def build_email_subject() -> str:
    year, month = previous_completed_month()
    report_month = date(year, month, 1).strftime("%B %Y")
    return f"{report_month} Snapshot and Caseload Reports"


def expected_report_files() -> tuple[Path, Path]:
    year, month = previous_completed_month()
    last_day = calendar.monthrange(year, month)[1]

    snapshot_filename = (
        f"Snapshot_eligenr_"
        f"{year:04d}{month:02d}{last_day:02d}"
        f"disabfix_v1.xlsx"
    )

    caseload_filename = (
        f"Caseload_Member_Days_"
        f"{year:04d}{month:02d}.xlsx"
    )

    return (
        BUDGET_FOLDER / snapshot_filename,
        BUDGET_FOLDER / caseload_filename,
    )


def validate_reports(snapshot_file: Path, caseload_file: Path) -> None:
    missing_files: list[str] = []

    if not snapshot_file.exists():
        missing_files.append(str(snapshot_file))

    if not caseload_file.exists():
        missing_files.append(str(caseload_file))

    if missing_files:
        missing_text = "\n".join(missing_files)

        raise FileNotFoundError(
            "Email was not sent because the following report file(s) "
            f"were not found:\n{missing_text}"
        )


def send_outlook_email(snapshot_file: Path, caseload_file: Path) -> None:
    outlook = win32com.client.Dispatch("Outlook.Application")
    message = outlook.CreateItem(0)

    message.To = "; ".join(RECIPIENTS)
    message.Subject = build_email_subject()

    message.Body = (
        "Ladies,\n\n"
        "The Monthly Snapshot and Caseload reports have been posted "
        "to the Budget shared folder for your review.\n\n"
        "Snapshot Report\n"
        f"    {snapshot_file.name}\n\n"
        "Caseload Report\n"
        f"    {caseload_file.name}\n\n"
        "Best regards,\n\n"
        "Tatyana Kray"
    )

    message.Send()


def main() -> None:
    write_log("=" * 65)
    write_log("Monthly Snapshot and Caseload email process started.")

    try:
        if not BUDGET_FOLDER.exists():
            raise FileNotFoundError(
                f"Budget shared folder is not available: {BUDGET_FOLDER}"
            )

        snapshot_file, caseload_file = expected_report_files()

        write_log(f"Expected Snapshot file: {snapshot_file.name}")
        write_log(f"Expected Caseload file: {caseload_file.name}")

        validate_reports(
            snapshot_file=snapshot_file,
            caseload_file=caseload_file,
        )

        write_log("Both expected report files were found.")

        send_outlook_email(
            snapshot_file=snapshot_file,
            caseload_file=caseload_file,
        )

        write_log(
            "SUCCESS: Notification email successfully sent to "
            + "; ".join(RECIPIENTS)
        )
        write_log("=" * 65)

    except Exception as error:
        write_log(f"ERROR: {error}")
        write_log("Email was not created or sent.")
        write_log("=" * 65)
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception:
        sys.exit(1)
