

create or replace view syncdt.refresh_queue_ux as
select
		id,
		derived_schema || '.' || derived_table as derived_table_name,
		source_schema || '.' || source_table as source_table_name,
		triggered_at,
		"filter",
		case when processed_at is not null then 'Done' 
			 when wait_until > now() then 'Waiting'
			 else 'Pending'
		end as status,
		processed_at,
		wait_until,
		derived_schema,
		derived_table,
		source_schema,
		source_table		
from
	syncdt._refresh_queue


