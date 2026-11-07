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
