select 1
where (select count(*) from {{ ref('fct_reconciliation') }})
   <> (select count(*) from {{ ref('stg_payroll_line') }})
