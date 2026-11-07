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
