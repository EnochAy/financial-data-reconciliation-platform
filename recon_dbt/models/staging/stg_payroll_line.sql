select
    line_id,
    payroll_run_id,
    employee_id,
    gross::numeric(14, 2) as gross_amount,
    deductions::numeric(14, 2) as deduction_amount,
    net_expected::numeric(14, 2) as net_expected_amount
from {{ source('raw', 'payroll_line') }}
