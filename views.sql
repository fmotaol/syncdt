

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
		source_table,
		last_try,
		last_error
from
	syncdt._refresh_queue



	
	
	
create or replace view syncdt.refresh_status as
select
		status,
		derived_schema || '.' || derived_table as derived_table_name,
		source_schema || '.' || source_table as source_table_name,
		count(*) as notifications,
		min(triggered_at) as oldest_req,
		max(triggered_at) as newest_req
from
	syncdt.refresh_queue_ux
group by 1, 2, 3
order by 1, 2, 3


	
	
	
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
	