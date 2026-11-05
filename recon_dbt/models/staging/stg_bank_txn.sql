select
    txn_id,
    disbursement_id,
    amount_settled::numeric(14, 2) as amount_settled,
    settled_ts::timestamp as settled_at,
    status as txn_status,
    failure_reason
from {{ source('raw', 'bank_txn') }}
