select
    payroll_run_id,
    entity_id,
    period as pay_period,
    run_date::date as run_date,
    status as run_status
from {{ source('raw', 'payroll_run') }}
