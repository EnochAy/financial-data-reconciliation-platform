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
