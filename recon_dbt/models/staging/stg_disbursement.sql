select
    disbursement_id,
    line_id,
    amount_sent::numeric(14, 2) as amount_sent,
    sent_ts::timestamp as sent_at,
    batch_id,
    channel
from {{ source('raw', 'disbursement') }}
