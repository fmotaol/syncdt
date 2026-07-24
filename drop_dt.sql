CREATE OR REPLACE FUNCTION syncdt.drop_derived_table(table_name TEXT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    schema_name TEXT;
    base_table_name TEXT;
    rec RECORD;
    start_time TIMESTAMPTZ;
BEGIN
    start_time := NOW();
    
    -- Extrai schema e nome da tabela
    IF position('.' in table_name) > 0 THEN
        schema_name := split_part(table_name, '.', 1);
        base_table_name := split_part(table_name, '.', 2);
    ELSE
        schema_name := 'public';
        base_table_name := table_name;
    END IF;

    -- Valida se a tabela existe nos metadados
    SELECT * INTO rec
    FROM syncdt._derived_tables d
    WHERE d.table_schema = schema_name AND d.table_name = base_table_name;

    IF NOT FOUND THEN
        --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        --VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), false, 
                --format('Tabela derivada %s.%s não encontrada nos metadados', schema_name, base_table_name));
        RAISE EXCEPTION 'Tabela derivada %.% não encontrada nos metadados', schema_name, base_table_name;
    END IF;

    -- Remove triggers
	for rec in select * 
		from syncdt._dependencies d
		where d.derived_schema = schema_name and d.derived_table = base_table_name 
	loop
		raise notice 'Removendo trigger % da tabela %', rec.trigger_name, table_name;	
	    PERFORM format('DROP TRIGGER IF EXISTS %s ON %s;', rec.trigger_name, table_name);
	end loop;

    -- Remove dependências e metadados
    DELETE FROM syncdt._dependencies d WHERE d.derived_schema = schema_name AND d.derived_table = base_table_name;
    DELETE FROM syncdt._derived_tables d WHERE d.table_schema = schema_name AND d.table_name = base_table_name;

    -- Remove a tabela física
    perform syncdt.execute('DROP TABLE IF EXISTS %I.%I CASCADE', schema_name, base_table_name);

    -- Log de sucesso
    --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success)
    --VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), true);

    RAISE NOTICE 'Tabela derivada %.% removida com sucesso', schema_name, base_table_name;

EXCEPTION
    WHEN OTHERS THEN
        --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        --VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), false, SQLERRM);
        RAISE;
END;
$$;




CREATE OR REPLACE FUNCTION syncdt.drop_dependency(
    derived_table TEXT,
    source_table TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
BEGIN
	raise exception 'ainda não implementado';
END;
$$;
