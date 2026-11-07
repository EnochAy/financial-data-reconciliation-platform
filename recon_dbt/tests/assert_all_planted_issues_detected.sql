select *
from {{ ref('qa_detection_scorecard') }}
where missed > 0 or false_alarms > 0
