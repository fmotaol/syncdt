



CREATE OR REPLACE FUNCTION syncdt._refresh_derived_table(
	derived_schema text,
    derived_table TEXT,
    filter text default null
)
RETURNS int 
LANGUAGE plpgsql
AS $$
DECLARE
	q text;
	w text;
	rc int;
BEGIN
	--retorna número de linhas
	select definition_query into q from syncdt._derived_tables d
		where d.table_schema = _refresh_derived_table.derived_schema and table_name = _refresh_derived_table.derived_table;

	if filter is null then
		w = '';
	else
		w = 'where ' || filter;
	end if;
		
    perform syncdt.execute('delete from %I.%I %s', derived_schema, derived_table, w);

    perform syncdt.execute('INSERT INTO %I.%I select * from (%s) %s', derived_schema, derived_table, q, w);
	
    GET DIAGNOSTICS rc = ROW_COUNT;
	return rc;
END;
$$;


CREATE OR replace FUNCTION syncdt.refresh_derived_table(
	table_name TEXT,
    filter text default null
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
	schema_name text;
	base_table_name text;
BEGIN
    IF position('.' in table_name) > 0 THEN
        schema_name := split_part(table_name, '.', 1);
        table_name := split_part(table_name, '.', 2);
    ELSE
        schema_name := 'public';
        table_name := table_name;
    END IF;

	perform syncdt._refresh_derived_table(schema_name, table_name, filter);
END;
$$;

