select entity_id, entity_name, entity_type
from {{ ref('stg_entity') }}
