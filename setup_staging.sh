#!/usr/bin/env bash
# Run from the repo root (recon-platform):  bash setup_staging.sh
# Creates the dbt sources, staging models, tests and schema macro inside recon_dbt/.
# It overwrites recon_dbt/dbt_project.yml and removes dbt's example models.
set -e

if [ ! -d recon_dbt ]; then
  echo "recon_dbt folder not found. Run this from the recon-platform folder." >&2
  exit 1
fi

cd recon_dbt
rm -rf models/example
mkdir -p models/staging models/marts macros

# ---------------------------------------------------------------- project file
cat > dbt_project.yml << 'EOF'
name: 'recon_dbt'
version: '1.0.0'
profile: 'recon_dbt'

model-paths: ["models"]
analysis-paths: ["analyses"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
snapshot-paths: ["snapshots"]

clean-targets:
  - "target"
  - "dbt_packages"

models:
  recon_dbt:
    staging:
      +materialized: view
      +schema: staging
    marts:
      +materialized: table
      +schema: marts
EOF

# Use the schema name exactly as configured (staging, marts) instead of
# dbt's default "<target schema>_<custom schema>" naming.
cat > macros/generate_schema_name.sql << 'EOF'
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
EOF

# -------------------------------------------------------------------- sources
cat > models/staging/_sources.yml << 'EOF'
version: 2

sources:
  - name: raw
    schema: raw
    description: Synthetic payroll, disbursement and bank settlement data. All data is fake.
    tables:
      - name: entity
      - name: employee
      - name: payroll_run
      - name: payroll_line
      - name: disbursement
      - name: bank_txn
EOF

# ------------------------------------------------------------ staging models
cat > models/staging/stg_entity.sql << 'EOF'
select
    entity_id,
    entity_name,
    entity_type
from {{ source('raw', 'entity') }}
EOF

cat > models/staging/stg_employee.sql << 'EOF'
select
    employee_id,
    entity_id,
    employee_name,
    grade,
    bank_code,
    masked_account_ref,
    status as employment_status
from {{ source('raw', 'employee') }}
EOF

cat > models/staging/stg_payroll_run.sql << 'EOF'
select
    payroll_run_id,
    entity_id,
    period as pay_period,
    run_date::date as run_date,
    status as run_status
from {{ source('raw', 'payroll_run') }}
EOF

cat > models/staging/stg_payroll_line.sql << 'EOF'
select
    line_id,
    payroll_run_id,
    employee_id,
    gross::numeric(14, 2) as gross_amount,
    deductions::numeric(14, 2) as deduction_amount,
    net_expected::numeric(14, 2) as net_expected_amount
from {{ source('raw', 'payroll_line') }}
EOF

cat > models/staging/stg_disbursement.sql << 'EOF'
select
    disbursement_id,
    line_id,
    amount_sent::numeric(14, 2) as amount_sent,
    sent_ts::timestamp as sent_at,
    batch_id,
    channel
from {{ source('raw', 'disbursement') }}
EOF

cat > models/staging/stg_bank_txn.sql << 'EOF'
select
    txn_id,
    disbursement_id,
    amount_settled::numeric(14, 2) as amount_settled,
    settled_ts::timestamp as settled_at,
    status as txn_status,
    failure_reason
from {{ source('raw', 'bank_txn') }}
EOF

# ---------------------------------------------------------------------- tests
# Note: no uniqueness test on stg_disbursement.line_id. A line paid twice is a
# business exception to detect in the marts, not a staging key violation.
cat > models/staging/_staging.yml << 'EOF'
version: 2

models:
  - name: stg_entity
    description: Organisations whose payroll is processed (synthetic).
    columns:
      - name: entity_id
        data_tests:
          - unique
          - not_null

  - name: stg_employee
    description: One row per employee, with a masked bank reference.
    columns:
      - name: employee_id
        data_tests:
          - unique
          - not_null
      - name: entity_id
        data_tests:
          - not_null
          - relationships:
              arguments:
                to: ref('stg_entity')
                field: entity_id

  - name: stg_payroll_run
    description: One payroll run per entity per period.
    columns:
      - name: payroll_run_id
        data_tests:
          - unique
          - not_null
      - name: entity_id
        data_tests:
          - relationships:
              arguments:
                to: ref('stg_entity')
                field: entity_id

  - name: stg_payroll_line
    description: What payroll says each employee should be paid in a run.
    columns:
      - name: line_id
        data_tests:
          - unique
          - not_null
      - name: payroll_run_id
        data_tests:
          - not_null
          - relationships:
              arguments:
                to: ref('stg_payroll_run')
                field: payroll_run_id
      - name: employee_id
        data_tests:
          - not_null
          - relationships:
              arguments:
                to: ref('stg_employee')
                field: employee_id

  - name: stg_disbursement
    description: Payments sent, one row per disbursement instruction.
    columns:
      - name: disbursement_id
        data_tests:
          - unique
          - not_null
      - name: line_id
        data_tests:
          - not_null
          - relationships:
              arguments:
                to: ref('stg_payroll_line')
                field: line_id

  - name: stg_bank_txn
    description: Bank settlement records. Orphans have no disbursement_id.
    columns:
      - name: txn_id
        data_tests:
          - unique
          - not_null
      - name: disbursement_id
        data_tests:
          - relationships:
              arguments:
                to: ref('stg_disbursement')
                field: disbursement_id
      - name: txn_status
        data_tests:
          - accepted_values:
              arguments:
                values: ['settled', 'failed']
EOF

echo "Done. Created dbt sources, 6 staging models, tests and the schema macro."
echo "Next: cd recon_dbt && dbt run && dbt test"
