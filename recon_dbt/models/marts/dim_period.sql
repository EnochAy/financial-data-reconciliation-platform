select distinct
    pay_period,
    to_date(pay_period || '-01', 'YYYY-MM-DD') as period_start
from {{ ref('stg_payroll_run') }}
