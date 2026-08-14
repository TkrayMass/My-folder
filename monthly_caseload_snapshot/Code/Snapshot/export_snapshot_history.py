import calendar
import os
from datetime import date
from pathlib import Path

import pandas as pd
import snowflake.connector
from cryptography.hazmat.primitives import serialization
from openpyxl import load_workbook


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

# Secret is stored outside source control.
PASSPHRASE = os.environ["SNAPSHOT_SNOWFLAKE_KEY_PWD"]

OUTPUT_FOLDER = Path(
    r"\\ehs.govt.state.ma.us\dfs\EHS\Boston_600_Washington_St"
    r"\File Services\Adhoc\JF\Budget"
)


def load_private_key() -> bytes:
    if not PRIVATE_KEY_FILE.exists():
        raise FileNotFoundError(
            f"Private key was not found: {PRIVATE_KEY_FILE}"
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


def build_filename(latest_yr_mth: int) -> str:
    year = latest_yr_mth // 100
    month = latest_yr_mth % 100
    last_day = calendar.monthrange(year, month)[1]
    snapshot_date = date(year, month, last_day)

    return (
        f"Snapshot_eligenr_"
        f"{snapshot_date:%Y%m%d}"
        f"disabfix_v1.xlsx"
    )


def format_workbook(file_path: Path) -> None:
    workbook = load_workbook(file_path)
    worksheet = workbook.active

    worksheet.freeze_panes = "A2"
    worksheet.auto_filter.ref = worksheet.dimensions

    worksheet.column_dimensions["A"].width = 12
    worksheet.column_dimensions["B"].width = 20
    worksheet.column_dimensions["C"].width = 14

    workbook.save(file_path)


def main() -> None:
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
            cursor.execute(
                """
                SELECT
                    YR_MTH,
                    CDE_BUDGET_GROUP,
                    MEMBERS
                FROM MHTEAM.MHA.SNAPSHOT_ELIGENR_HISTORY
                ORDER BY
                    YR_MTH,
                    CDE_BUDGET_GROUP
                """
            )
            rows = cursor.fetchall()
            columns = [column[0] for column in cursor.description]
        finally:
            cursor.close()
    finally:
        connection.close()

    if not rows:
        raise RuntimeError(
            "SNAPSHOT_ELIGENR_HISTORY returned no rows."
        )

    report = pd.DataFrame(rows, columns=columns)

    report["CDE_BUDGET_GROUP"] = (
        report["CDE_BUDGET_GROUP"]
        .astype(str)
        .str.strip()
        .str.zfill(2)
    )

    report = report.sort_values(
        by=["YR_MTH", "CDE_BUDGET_GROUP"],
        ascending=[True, True],
    )

    latest_yr_mth = int(report["YR_MTH"].max())
    output_filename = build_filename(latest_yr_mth)
    output_path = OUTPUT_FOLDER / output_filename

    OUTPUT_FOLDER.mkdir(parents=True, exist_ok=True)

    sheet_name = output_filename.replace(".xlsx", "")[:31]

    report.to_excel(
        output_path,
        index=False,
        sheet_name=sheet_name,
        engine="openpyxl",
    )

    format_workbook(output_path)

    print()
    print("SUCCESS!")
    print(f"Rows exported: {len(report):,}")
    print(f"First month: {int(report['YR_MTH'].min())}")
    print(f"Latest month: {latest_yr_mth}")
    print(f"Excel file: {output_path}")


if __name__ == "__main__":
    main()
