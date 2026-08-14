import calendar
import os
import shutil
from datetime import date
from pathlib import Path

import pandas as pd
import snowflake.connector
from cryptography.hazmat.primitives import serialization
from openpyxl import load_workbook
from openpyxl.styles import Font


ACCOUNT = "MAEOHHS-MAHDW_PROD"
USER = "TATYANA.KRAY@MASS.GOV"
ROLE = "MHA_TEAM_ROLE"
WAREHOUSE = "MHA_WH"
DATABASE = "MHTEAM"
SCHEMA = "MHA"

PRIVATE_KEY_FILE = Path(
    r"C:\Users\TKray\OneDrive - Commonwealth of Massachusetts"
    r"\Documents\key\krayt_rsa_key_1.p8"
)

PASSPHRASE = os.environ["SNAPSHOT_SNOWFLAKE_KEY_PWD"]

LOCAL_OUTPUT_FOLDER = Path(
    r"C:\Users\TKray\Documents\Caseload_Automation\Output"
)

SHARED_OUTPUT_FOLDER = Path(
    r"\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St"
    r"\File Services\Adhoc\JF\Budget"
)

TASK_NAME = "CASELOAD_MONTHLY_REFRESH_TASK"
SOURCE_TABLE = "MHTEAM.MHA.CASELOAD_MEMBER_DAYS"


def load_private_key() -> bytes:
    if not PRIVATE_KEY_FILE.exists():
        raise FileNotFoundError(
            f"Private-key file was not found: {PRIVATE_KEY_FILE}"
        )

    with PRIVATE_KEY_FILE.open("rb") as key_file:
        private_key = serialization.load_pem_private_key(
            key_file.read(),
            password=PASSPHRASE.encode("utf-8"),
        )

    return private_key.private_bytes(
        encoding=serialization.Encoding.DER,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )


def expected_latest_yr_mth() -> int:
    today = date.today()

    if today.month == 1:
        previous_year = today.year - 1
        previous_month = 12
    else:
        previous_year = today.year
        previous_month = today.month - 1

    return previous_year * 100 + previous_month


def build_filename(latest_yr_mth: int) -> str:
    """Create the production filename using YYYYMM."""
    return f"Caseload_Member_Days_{latest_yr_mth}.xlsx"


def verify_task_success(cursor) -> None:
    cursor.execute(
        """
        SELECT
            NAME,
            STATE,
            SCHEDULED_TIME,
            QUERY_START_TIME,
            COMPLETED_TIME,
            ERROR_CODE,
            ERROR_MESSAGE
        FROM TABLE(
            MHTEAM.INFORMATION_SCHEMA.TASK_HISTORY(
                TASK_NAME => 'CASELOAD_MONTHLY_REFRESH_TASK',
                SCHEDULED_TIME_RANGE_START =>
                    DATE_TRUNC('DAY', CURRENT_TIMESTAMP()),
                SCHEDULED_TIME_RANGE_END =>
                    DATEADD(
                        DAY,
                        1,
                        DATE_TRUNC('DAY', CURRENT_TIMESTAMP())
                    ),
                RESULT_LIMIT => 20
            )
        )
        WHERE QUERY_ID IS NOT NULL
        ORDER BY SCHEDULED_TIME DESC
        LIMIT 1
        """
    )

    result = cursor.fetchone()

    if result is None:
        raise RuntimeError(
            "No Caseload Snowflake task execution was found for today. "
            "The Excel export was not created."
        )

    (
        task_name,
        state,
        scheduled_time,
        query_start_time,
        completed_time,
        error_code,
        error_message,
    ) = result

    if str(state).upper() != "SUCCEEDED":
        raise RuntimeError(
            "The Caseload Snowflake task did not succeed. "
            f"Task={task_name}; "
            f"State={state}; "
            f"Scheduled={scheduled_time}; "
            f"Started={query_start_time}; "
            f"Completed={completed_time}; "
            f"Error code={error_code}; "
            f"Error={error_message}"
        )

    print("Snowflake task verification passed.")
    print(f"Task state: {state}")
    print(f"Task started: {query_start_time}")
    print(f"Task completed: {completed_time}")


def read_and_validate_caseload(cursor) -> pd.DataFrame:
    cursor.execute(
        f"""
        SELECT
            YR_MTH,
            CDE_BUDGET_GROUP,
            MEM_DAYS
        FROM {SOURCE_TABLE}
        ORDER BY
            YR_MTH,
            CDE_BUDGET_GROUP
        """
    )

    rows = cursor.fetchall()
    columns = [column[0] for column in cursor.description]

    if not rows:
        raise RuntimeError(
            f"{SOURCE_TABLE} returned no rows."
        )

    report = pd.DataFrame(rows, columns=columns)

    report["YR_MTH"] = pd.to_numeric(
        report["YR_MTH"],
        errors="raise",
    ).astype(int)

    report["MEM_DAYS"] = pd.to_numeric(
        report["MEM_DAYS"],
        errors="raise",
    )

    report["CDE_BUDGET_GROUP"] = (
        report["CDE_BUDGET_GROUP"]
        .fillna("00")
        .astype(str)
        .str.strip()
        .str.zfill(2)
    )

    report = report.sort_values(
        by=["YR_MTH", "CDE_BUDGET_GROUP"],
        ascending=[True, True],
    ).reset_index(drop=True)

    expected_latest = expected_latest_yr_mth()
    actual_latest = int(report["YR_MTH"].max())
    actual_first = int(report["YR_MTH"].min())
    actual_month_count = int(report["YR_MTH"].nunique())

    if actual_latest != expected_latest:
        raise RuntimeError(
            "Caseload table is not current. "
            f"Expected latest month={expected_latest}, "
            f"but table latest month={actual_latest}."
        )

    if actual_first != 200607:
        raise RuntimeError(
            "Caseload table has an unexpected starting month. "
            f"Expected 200607, but found {actual_first}."
        )

    duplicate_count = int(
        report.duplicated(
            subset=["YR_MTH", "CDE_BUDGET_GROUP"]
        ).sum()
    )

    if duplicate_count > 0:
        raise RuntimeError(
            "Caseload QC failed: "
            f"{duplicate_count} duplicate month/budget-group rows found."
        )

    if report["MEM_DAYS"].isna().any():
        raise RuntimeError(
            "Caseload QC failed: MEM_DAYS contains missing values."
        )

    if (report["MEM_DAYS"] < 0).any():
        raise RuntimeError(
            "Caseload QC failed: negative MEM_DAYS values were found."
        )

    total_member_days = report["MEM_DAYS"].sum()

    if total_member_days <= 0:
        raise RuntimeError(
            "Caseload QC failed: total member-days is zero or negative."
        )

    print("Caseload table QC passed.")
    print(f"Rows: {len(report):,}")
    print(f"First month: {actual_first}")
    print(f"Latest month: {actual_latest}")
    print(f"Distinct months: {actual_month_count}")
    print(f"Total member-days: {total_member_days:,.0f}")

    return report


def format_workbook(file_path: Path) -> None:
    workbook = load_workbook(file_path)
    worksheet = workbook.active

    worksheet.freeze_panes = "A2"
    worksheet.auto_filter.ref = worksheet.dimensions

    for cell in worksheet[1]:
        cell.font = Font(bold=True)

    worksheet.column_dimensions["A"].width = 12
    worksheet.column_dimensions["B"].width = 20
    worksheet.column_dimensions["C"].width = 18

    for cell in worksheet["B"][1:]:
        cell.number_format = "@"

    for cell in worksheet["C"][1:]:
        cell.number_format = "#,##0"

    workbook.save(file_path)


def save_excel_report(
    report: pd.DataFrame,
    local_output_path: Path,
) -> None:
    report.to_excel(
        local_output_path,
        index=False,
        sheet_name="Caseload Member Days",
        engine="openpyxl",
    )

    format_workbook(local_output_path)


def copy_to_shared_folder(
    local_output_path: Path,
    shared_output_path: Path,
) -> None:
    if not SHARED_OUTPUT_FOLDER.exists():
        raise FileNotFoundError(
            "The shared Budget folder is not available: "
            f"{SHARED_OUTPUT_FOLDER}"
        )

    shutil.copy2(
        local_output_path,
        shared_output_path,
    )

    if not shared_output_path.exists():
        raise RuntimeError(
            "The report was created locally but could not be confirmed "
            f"in the shared folder: {shared_output_path}"
        )


def main() -> None:
    print()
    print("=" * 65)
    print("MONTHLY CASELOAD EXPORT")
    print("=" * 65)

    LOCAL_OUTPUT_FOLDER.mkdir(
        parents=True,
        exist_ok=True,
    )

    private_key = load_private_key()

    connection = snowflake.connector.connect(
        account=ACCOUNT,
        user=USER,
        private_key=private_key,
        role=ROLE,
        warehouse=WAREHOUSE,
        database=DATABASE,
        schema=SCHEMA,
    )

    try:
        cursor = connection.cursor()

        try:
            verify_task_success(cursor)
            report = read_and_validate_caseload(cursor)

        finally:
            cursor.close()

    finally:
        connection.close()

    latest_yr_mth = int(report["YR_MTH"].max())
    output_filename = build_filename(latest_yr_mth)

    local_output_path = (
        LOCAL_OUTPUT_FOLDER / output_filename
    )

    shared_output_path = (
        SHARED_OUTPUT_FOLDER / output_filename
    )

    save_excel_report(
        report=report,
        local_output_path=local_output_path,
    )

    print(f"Local Excel file created: {local_output_path}")

    copy_to_shared_folder(
        local_output_path=local_output_path,
        shared_output_path=shared_output_path,
    )

    print()
    print("SUCCESS!")
    print(f"Rows exported: {len(report):,}")
    print(f"First month: {int(report['YR_MTH'].min())}")
    print(f"Latest month: {latest_yr_mth}")
    print(f"Local copy: {local_output_path}")
    print(f"Shared copy: {shared_output_path}")


if __name__ == "__main__":
    main()
