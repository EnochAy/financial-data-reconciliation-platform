#!/usr/bin/env bash
# Run from the repo root (recon-platform):  bash setup_marts.sh
# Adds the intermediate and marts layers, the validation scorecard and their tests.
# It overwrites recon_dbt/dbt_project.yml (adds the intermediate layer and the SLA variable).
# Do not re-run setup_staging.sh afterwards: it would overwrite dbt_project.yml again.
set -e

if [ ! -d recon_dbt/models/staging ]; then
  echo "Staging models not found. Run setup_staging.sh first, from the recon-platform folder." >&2
  exit 1
fi

cd recon_dbt
mkdir -p models/intermediate models/marts tests

# ---------------------------------------------------------------- project file
cat > dbt_project.yml << 'EOF'
name: 'recon_dbt'
version: '1.0.0'
profile: 'recon_dbt'

model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

clean-targets:
  - "target"
  - "dbt_packages"

vars:
  # A payment settled more than this many days after it was sent is "late".
  settlement_sla_days: 3

models:
  recon_dbt:
    staging:
      +materialized: view
      +schema: staging
    intermediate:
      +materialized: view
      +schema: intermediate
    marts:
      +materialized: table
      +schema: marts
EOF

# --------------------------------------------------------------- intermediate
cat > models/intermediate/int_disbursement_checks.sql << 'EOF'
-- One row per disbursement, with its bank settlement outcome and the checks
-- that can be decided at disbursement level.
--
-- Business rules
--   amount mismatch : amount sent differs from what payroll expected
--   late settlement : settled, never failed, and settled after the SLA
--   failed, no retry: every bank attempt failed, none settled
--   recovered       : failed at least once but eventually settled. Its delay is
--                     explained by the retry, so it is not counted as late.

with disbursement as (
    select * from {{ ref('stg_disbursement') }}
),

payroll_line as (
    select line_id, net_expected_amount from {{ ref('stg_payroll_line') }}
),

settlement as (
    select
        disbursement_id,
        count(*) filter (where txn_status = 'settled') as settled_txn_count,
        count(*) filter (where txn_status = 'failed') as failed_txn_count,
        coalesce(sum(amount_settled) filter (where txn_status = 'settled'), 0) as amount_settled,
        min(settled_at) filter (where txn_status = 'settled') as settled_at
    from {{ ref('stg_bank_txn') }}
    where disbursement_id is not null
    group by disbursement_id
),

joined as (
    select
        d.disbursement_id,
        d.line_id,
        d.sent_at,
        d.amount_sent,
        p.net_expected_amount,
        coalesce(s.settled_txn_count, 0) as settled_txn_count,
        coalesce(s.failed_txn_count, 0) as failed_txn_count,
        coalesce(s.amount_settled, 0) as amount_settled,
        s.settled_at
    from disbursement d
    inner join payroll_line p on p.line_id = d.line_id
    left join settlement s on s.disbursement_id = d.disbursement_id
)

select
    *,
    extract(epoch from (settled_at - sent_at)) / 3600.0 as hours_to_settle,
    amount_sent <> net_expected_amount as is_amount_mismatch,
    (
        settled_txn_count > 0
        and failed_txn_count = 0
        and settled_at > sent_at + interval '{{ var("settlement_sla_days") }} days'
    ) as is_late_settlement,
    (settled_txn_count = 0 and failed_txn_count > 0) as is_failed_no_retry,
    (settled_txn_count > 0 and failed_txn_count > 0) as is_recovered_after_retry
from joined
EOF

# ---------------------------------------------------------------------- marts
cat > models/marts/fct_reconciliation.sql << 'EOF'
-- One row per payroll line: what payroll expected, what was sent, what the bank
-- settled, and a single reconciliation status.

with payroll_line as (
    select * from {{ ref('stg_payroll_line') }}
),

payroll_run as (
    select payroll_run_id, entity_id, pay_period from {{ ref('stg_payroll_run') }}
),

disbursement_rollup as (
    select
        line_id,
        count(*) as disbursement_count,
        sum(amount_sent) as amount_sent_total,
        sum(amount_settled) as amount_settled_total,
        min(sent_at) as first_sent_at,
        max(settled_at) as last_settled_at,
        max(hours_to_settle) as max_hours_to_settle,
        bool_or(is_amount_mismatch) as has_amount_mismatch,
        bool_or(is_late_settlement) as has_late_settlement,
        bool_or(is_failed_no_retry) as has_failed_no_retry,
        bool_or(is_recovered_after_retry) as has_recovered_after_retry
    from {{ ref('int_disbursement_checks') }}
    group by line_id
),

joined as (
    select
        l.line_id,
        l.payroll_run_id,
        r.entity_id,
        r.pay_period,
        l.employee_id,
        l.net_expected_amount,
        coalesce(d.disbursement_count, 0) as disbursement_count,
        coalesce(d.amount_sent_total, 0) as amount_sent_total,
        coalesce(d.amount_settled_total, 0) as amount_settled_total,
        d.first_sent_at,
        d.last_settled_at,
        d.max_hours_to_settle,
        coalesce(d.disbursement_count, 0) = 0 as is_missing_disbursement,
        coalesce(d.disbursement_count, 0) > 1 as is_duplicate_disbursement,
        coalesce(d.has_amount_mismatch, false) as is_amount_mismatch,
        coalesce(d.has_late_settlement, false) as is_late_settlement,
        coalesce(d.has_failed_no_retry, false) as is_failed_no_retry,
        coalesce(d.has_recovered_after_retry, false) as is_recovered_after_retry
    from payroll_line l
    inner join payroll_run r on r.payroll_run_id = l.payroll_run_id
    left join disbursement_rollup d on d.line_id = l.line_id
)

select
    *,
    (
        is_missing_disbursement::int
        + is_duplicate_disbursement::int
        + is_amount_mismatch::int
        + is_late_settlement::int
        + is_failed_no_retry::int
    ) as exception_count,
    case
        when is_missing_disbursement then 'missing_disbursement'
        when is_duplicate_disbursement then 'duplicate_disbursement'
        when is_amount_mismatch then 'amount_mismatch'
        when is_failed_no_retry then 'failed_no_retry'
        when is_late_settlement then 'late_settlement'
        when is_recovered_after_retry then 'reconciled_after_retry'
        else 'reconciled'
    end as reconciliation_status,
    amount_settled_total - net_expected_amount as variance_amount
from joined
EOF

cat > models/marts/fct_exceptions.sql << 'EOF'
-- One row per exception, traceable to a single record (line, disbursement or bank txn).
-- exposure_amount: money at stake. Overpayment for duplicates, absolute difference for
-- mismatches, and the expected payment for missing, late and failed payments.

with checks as (
    select * from {{ ref('int_disbursement_checks') }}
),

recon as (
    select * from {{ ref('fct_reconciliation') }}
),

exceptions as (

    select 'missing_disbursement' as issue_type, 'line_id' as key_type, line_id as key_id,
           line_id, entity_id, pay_period, net_expected_amount as exposure_amount
    from recon
    where is_missing_disbursement

    union all

    select 'duplicate_disbursement', 'line_id', line_id,
           line_id, entity_id, pay_period, amount_settled_total - net_expected_amount
    from recon
    where is_duplicate_disbursement

    union all

    select 'amount_mismatch', 'disbursement_id', c.disbursement_id,
           c.line_id, r.entity_id, r.pay_period, abs(c.amount_sent - c.net_expected_amount)
    from checks c
    inner join recon r on r.line_id = c.line_id
    where c.is_amount_mismatch

    union all

    select 'late_settlement', 'disbursement_id', c.disbursement_id,
           c.line_id, r.entity_id, r.pay_period, c.net_expected_amount
    from checks c
    inner join recon r on r.line_id = c.line_id
    where c.is_late_settlement

    union all

    select 'failed_no_retry', 'disbursement_id', c.disbursement_id,
           c.line_id, r.entity_id, r.pay_period, c.net_expected_amount
    from checks c
    inner join recon r on r.line_id = c.line_id
    where c.is_failed_no_retry

    union all

    -- Orphans cannot be attributed to a line, entity or period.
    select 'orphan_bank_txn', 'txn_id', txn_id,
           null::text, null::text, null::text, amount_settled
    from {{ ref('stg_bank_txn') }}
    where disbursement_id is null

)

select
    issue_type || ':' || key_id as exception_id,
    *
from exceptions
EOF

cat > models/marts/fct_recon_summary.sql << 'EOF'
-- One row per entity and pay period, for dashboards.
-- Orphan bank transactions are excluded because they cannot be attributed.

select
    entity_id || '-' || pay_period as summary_key,
    entity_id,
    pay_period,
    count(*) as payroll_lines,
    count(*) filter (where exception_count = 0) as clean_lines,
    count(*) filter (where exception_count > 0) as exception_lines,
    round(100.0 * count(*) filter (where exception_count = 0) / count(*), 2) as reconciliation_rate_pct,
    sum(net_expected_amount) as expected_amount,
    sum(amount_settled_total) as settled_amount,
    sum(variance_amount) as net_variance_amount,
    count(*) filter (where is_missing_disbursement) as missing_disbursements,
    count(*) filter (where is_duplicate_disbursement) as duplicate_disbursements,
    count(*) filter (where is_amount_mismatch) as amount_mismatches,
    count(*) filter (where is_late_settlement) as late_settlements,
    count(*) filter (where is_failed_no_retry) as failed_no_retry,
    count(*) filter (where is_recovered_after_retry) as recovered_after_retry
from {{ ref('fct_reconciliation') }}
group by entity_id, pay_period
EOF

cat > models/marts/dim_entity.sql << 'EOF'
select entity_id, entity_name, entity_type
from {{ ref('stg_entity') }}
EOF

cat > models/marts/dim_period.sql << 'EOF'
select distinct
    pay_period,
    to_date(pay_period || '-01', 'YYYY-MM-DD') as period_start
from {{ ref('stg_payroll_run') }}
EOF

cat > models/marts/qa_detection_scorecard.sql << 'EOF'
-- Compares what the exception logic detected with what the generator planted
-- (truth.planted_issues). Used only for validation, never to detect anything.

with detected as (
    select issue_type, key_id from {{ ref('fct_exceptions') }}
),

truth as (
    select issue_type, key_id from {{ source('truth', 'planted_issues') }}
),

comparison as (
    select
        coalesce(t.issue_type, d.issue_type) as issue_type,
        t.key_id is not null as in_truth,
        d.key_id is not null as in_detected
    from truth t
    full outer join detected d
        on t.issue_type = d.issue_type
        and t.key_id = d.key_id
)

select
    issue_type,
    count(*) filter (where in_truth) as planted,
    count(*) filter (where in_detected) as detected,
    count(*) filter (where in_truth and in_detected) as matched,
    count(*) filter (where in_truth and not in_detected) as missed,
    count(*) filter (where in_detected and not in_truth) as false_alarms,
    round(100.0 * count(*) filter (where in_truth and in_detected)
        / nullif(count(*) filter (where in_truth), 0), 2) as recall_pct,
    round(100.0 * count(*) filter (where in_truth and in_detected)
        / nullif(count(*) filter (where in_detected), 0), 2) as precision_pct
from comparison
group by issue_type
EOF

# -------------------------------------------------------------- sources, tests
cat > models/marts/_sources_truth.yml << 'EOF'
version: 2

sources:
  - name: truth
    schema: truth
    description: Ground truth written by the data generator. Used only for validation.
    tables:
      - name: planted_issues
EOF

cat > models/marts/_marts.yml << 'EOF'
version: 2

models:
  - name: fct_reconciliation
    description: One row per payroll line with expected, sent and settled amounts and a reconciliation status.
    columns:
      - name: line_id
        data_tests:
          - unique
          - not_null
          - relationships:
              arguments:
                to: ref('stg_payroll_line')
                field: line_id
      - name: reconciliation_status
        data_tests:
          - not_null
          - accepted_values:
              arguments:
                values: ['reconciled', 'reconciled_after_retry', 'missing_disbursement', 'duplicate_disbursement', 'amount_mismatch', 'late_settlement', 'failed_no_retry']

  - name: fct_exceptions
    description: One row per exception, traceable to a single line, disbursement or bank transaction.
    columns:
      - name: exception_id
        data_tests:
          - unique
          - not_null
      - name: issue_type
        data_tests:
          - accepted_values:
              arguments:
                values: ['missing_disbursement', 'duplicate_disbursement', 'amount_mismatch', 'late_settlement', 'failed_no_retry', 'orphan_bank_txn']

  - name: fct_recon_summary
    description: Reconciliation health by entity and pay period.
    columns:
      - name: summary_key
        data_tests:
          - unique
          - not_null

  - name: dim_entity
    columns:
      - name: entity_id
        data_tests:
          - unique
          - not_null

  - name: dim_period
    columns:
      - name: pay_period
        data_tests:
          - unique
          - not_null

  - name: qa_detection_scorecard
    description: Planted versus detected issues, by issue type.
EOF

# Every planted issue must be detected, with no false alarms.
cat > tests/assert_all_planted_issues_detected.sql << 'EOF'
select *
from {{ ref('qa_detection_scorecard') }}
where missed > 0 or false_alarms > 0
EOF

# The reconciliation table must cover every payroll line exactly once.
cat > tests/assert_recon_covers_every_line.sql << 'EOF'
select 1
where (select count(*) from {{ ref('fct_reconciliation') }})
   <> (select count(*) from {{ ref('stg_payroll_line') }})
EOF

echo "Done. Created int_disbursement_checks, 4 marts models, the scorecard and their tests."
echo "Next: cd recon_dbt && dbt build"
