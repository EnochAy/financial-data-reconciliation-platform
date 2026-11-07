-- Compares what the exception logic detected with what the generator planted
-- (truth.planted_issues). Used only for validation, never to detect anything.

with detected as (
    select issue_type, key_id from {{ ref('fct_exceptions') }}
),

truth as (
    select issue_type, key_id from {{ source('truth', 'planted_issues') }}
),

comparison as (
    select
        coalesce(t.issue_type, d.issue_type) as issue_type,
        t.key_id is not null as in_truth,
        d.key_id is not null as in_detected
    from truth t
    full outer join detected d
        on t.issue_type = d.issue_type
        and t.key_id = d.key_id
)

select
    issue_type,
    count(*) filter (where in_truth) as planted,
    count(*) filter (where in_detected) as detected,
    count(*) filter (where in_truth and in_detected) as matched,
    count(*) filter (where in_truth and not in_detected) as missed,
    count(*) filter (where in_detected and not in_truth) as false_alarms,
    round(100.0 * count(*) filter (where in_truth and in_detected)
        / nullif(count(*) filter (where in_truth), 0), 2) as recall_pct,
    round(100.0 * count(*) filter (where in_truth and in_detected)
        / nullif(count(*) filter (where in_detected), 0), 2) as precision_pct
from comparison
group by issue_type
