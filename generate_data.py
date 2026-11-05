"""Synthetic payroll / disbursement / bank-settlement data for the
Financial Data Quality & Reconciliation Platform.

All data is fake. Issues are planted at known rates and recorded in
truth.planted_issues, so the dbt exception logic can be validated against it.

Usage:
    python generate_data.py              # builds tables and loads them to PostgreSQL
    DATABASE_URL=... python generate_data.py   # override the connection string
"""
import os
import random
from datetime import datetime, timedelta
from itertools import count

import pandas as pd
from faker import Faker

SEED = 42
DB_URL = os.getenv(
    "DATABASE_URL",
    "postgresql+psycopg2://recon:recon_dev@localhost:5433/recon_platform",
)

PERIODS = ["2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08"]
EMP_PER_ENTITY = 2000          # 4 entities x 2,000 x 6 periods = 48,000 payroll lines
SLA_DAYS = 3                   # settlement SLA used to define "late"
GRADES = {"G1": (60_000, 90_000), "G2": (90_000, 140_000),
          "G3": (140_000, 220_000), "G4": (220_000, 350_000)}
BANK_CODES = ["011", "033", "044", "057", "058"]

# Cumulative thresholds on one random draw per payroll line, so each line
# gets at most one planted issue and the ground truth stays clean.
T_MISSING, T_DUPLICATE, T_MISMATCH, T_LATE = 0.010, 0.018, 0.030, 0.045
T_FAILED_NO_RETRY, T_FAILED_RETRY = 0.055, 0.065   # the second is normal noise, not an issue
ORPHAN_RATE = 0.003            # extra bank txns with no disbursement

NUMERIC_COLS = {
    "payroll_line": ["gross", "deductions", "net_expected"],
    "disbursement": ["amount_sent"],
    "bank_txn": ["amount_settled"],
}


def build_tables():
    random.seed(SEED)
    Faker.seed(SEED)
    fake = Faker()

    entity = pd.DataFrame(
        [("E01", "Entity A", "local_govt"), ("E02", "Entity B", "pension"),
         ("E03", "Entity C", "education_board"), ("E04", "Entity D", "state")],
        columns=["entity_id", "entity_name", "entity_type"],
    )

    # Employees
    emps = []
    for e in entity.entity_id:
        for i in range(EMP_PER_ENTITY):
            emps.append({
                "employee_id": f"{e}-{i:05d}",
                "entity_id": e,
                "employee_name": fake.name(),
                "grade": random.choices(list(GRADES), weights=[40, 30, 20, 10])[0],
                "bank_code": random.choice(BANK_CODES),
                "masked_account_ref": f"****{random.randint(0, 9999):04d}",
                "status": "active",
            })
    employee = pd.DataFrame(emps)

    # Payroll runs
    runs = [{
        "payroll_run_id": f"{e}-{p}", "entity_id": e, "period": p,
        "run_date": datetime.strptime(p + "-25", "%Y-%m-%d").date(), "status": "approved",
    } for e in entity.entity_id for p in PERIODS]
    payroll_run = pd.DataFrame(runs)
    run_date = dict(zip(payroll_run.payroll_run_id, payroll_run.run_date))

    # Payroll lines
    lines, n = [], 0
    for emp in employee.itertuples():
        lo, hi = GRADES[emp.grade]
        base = random.randint(lo, hi)
        for p in PERIODS:
            n += 1
            gross = round(base * random.uniform(0.98, 1.02), 2)
            ded = round(gross * 0.15, 2)
            lines.append({
                "line_id": f"L{n:07d}",
                "payroll_run_id": f"{emp.entity_id}-{p}",
                "employee_id": emp.employee_id,
                "gross": gross, "deductions": ded,
                "net_expected": round(gross - ded, 2),
            })
    payroll_line = pd.DataFrame(lines)

    # Disbursements, bank transactions and planted issues
    disb, txns, planted = [], [], []
    d_id, t_id = count(1), count(1)

    def make_disb(line, amount, sent_ts):
        did = f"D{next(d_id):07d}"
        disb.append({
            "disbursement_id": did, "line_id": line.line_id, "amount_sent": amount,
            "sent_ts": sent_ts, "batch_id": f"{line.payroll_run_id}-B{random.randint(1, 5)}",
            "channel": "bank_transfer",
        })
        return did

    def make_txn(did, amount, settled_ts, status="settled", reason=None):
        tid = f"T{next(t_id):07d}"
        txns.append({
            "txn_id": tid, "disbursement_id": did, "amount_settled": amount,
            "settled_ts": settled_ts, "status": status, "failure_reason": reason,
        })
        return tid

    def flag(issue, key_type, key):
        planted.append({"issue_type": issue, "key_type": key_type, "key_id": key})

    def normal_settle(sent):
        return sent + timedelta(days=random.choice([1, 1, 2]), hours=random.randint(0, 6))

    for l in payroll_line.itertuples():
        sent = datetime.combine(run_date[l.payroll_run_id], datetime.min.time()) \
            + timedelta(hours=random.randint(8, 20))
        r = random.random()

        if r < T_MISSING:                       # payroll line, no disbursement at all
            flag("missing_disbursement", "line_id", l.line_id)
            continue

        did = make_disb(l, l.net_expected, sent)

        if r < T_DUPLICATE:                     # same line paid twice
            did2 = make_disb(l, l.net_expected, sent + timedelta(hours=1))
            make_txn(did, l.net_expected, normal_settle(sent))
            make_txn(did2, l.net_expected, normal_settle(sent + timedelta(hours=1)))
            flag("duplicate_disbursement", "line_id", l.line_id)
        elif r < T_MISMATCH:                    # amount sent differs from payroll
            wrong = round(l.net_expected * random.choice([0.90, 1.10]), 2)
            disb[-1]["amount_sent"] = wrong
            make_txn(did, wrong, normal_settle(sent))
            flag("amount_mismatch", "disbursement_id", did)
        elif r < T_LATE:                        # settled well outside SLA
            late = sent + timedelta(days=random.randint(SLA_DAYS + 3, SLA_DAYS + 7))
            make_txn(did, l.net_expected, late)
            flag("late_settlement", "disbursement_id", did)
        elif r < T_FAILED_NO_RETRY:             # failed and never retried
            make_txn(did, 0.0, normal_settle(sent), "failed",
                     random.choice(["insufficient_funds", "invalid_account", "timeout"]))
            flag("failed_no_retry", "disbursement_id", did)
        elif r < T_FAILED_RETRY:                # failed, then retried successfully (not an issue)
            first = normal_settle(sent)
            make_txn(did, 0.0, first, "failed", random.choice(["timeout", "bank_unavailable"]))
            make_txn(did, l.net_expected, first + timedelta(days=2))
        else:                                   # clean payment
            make_txn(did, l.net_expected, normal_settle(sent))

    # Orphan bank transactions: money settled with no matching disbursement
    for _ in range(int(len(txns) * ORPHAN_RATE)):
        anchor = random.choice(disb)["sent_ts"]
        tid = make_txn(None, round(random.uniform(20_000, 300_000), 2),
                       anchor + timedelta(days=1))
        flag("orphan_bank_txn", "txn_id", tid)

    return {
        ("raw", "entity"): entity,
        ("raw", "employee"): employee,
        ("raw", "payroll_run"): payroll_run,
        ("raw", "payroll_line"): payroll_line,
        ("raw", "disbursement"): pd.DataFrame(disb),
        ("raw", "bank_txn"): pd.DataFrame(txns),
        ("truth", "planted_issues"): pd.DataFrame(planted),
    }


def load(tables):
    from sqlalchemy import create_engine, text
    from sqlalchemy.types import Numeric

    engine = create_engine(DB_URL)
    with engine.begin() as conn:
        for schema in ("raw", "truth"):
            conn.execute(text(f"CREATE SCHEMA IF NOT EXISTS {schema}"))

    for (schema, name), df in tables.items():
        dtype = {c: Numeric(14, 2) for c in NUMERIC_COLS.get(name, [])}
        df.to_sql(name, engine, schema=schema, if_exists="replace", index=False,
                  chunksize=5000, method="multi", dtype=dtype)
        print(f"{schema}.{name}: {len(df):,} rows")


if __name__ == "__main__":
    tables = build_tables()
    total = sum(len(df) for key, df in tables.items() if key[0] == "raw")
    print(f"Built {total:,} raw rows. Loading...")
    load(tables)
    print("\nPlanted issues:")
    print(tables[("truth", "planted_issues")].issue_type.value_counts().to_string())
