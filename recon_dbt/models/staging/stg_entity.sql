select
    entity_id,
    entity_name,
    entity_type
from {{ source('raw', 'entity') }}
