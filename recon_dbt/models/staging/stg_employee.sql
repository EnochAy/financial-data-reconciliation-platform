select
    employee_id,
    entity_id,
    employee_name,
    grade,
    bank_code,
    masked_account_ref,
    status as employment_status
from {{ source('raw', 'employee') }}
