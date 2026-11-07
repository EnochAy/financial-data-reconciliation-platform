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
