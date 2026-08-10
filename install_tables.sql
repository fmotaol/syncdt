
CREATE OR REPLACE FUNCTION syncdt._install_tables()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Tabela de metadados
	CREATE TABLE IF NOT EXISTS syncdt._derived_tables (
	    table_schema TEXT NOT NULL,
	    table_name TEXT NOT NULL,
	    definition_query TEXT NOT NULL,
	    refresh_mode TEXT NOT NULL,
	    primary_key TEXT,
	    created_at TIMESTAMPTZ NOT NULL,
	    updated_at TIMESTAMPTZ DEFAULT NOW(),
	    notification_mode text default 'optimized', --optimized, full
	    PRIMARY KEY (table_schema, table_name)
	);


    -- Tabela de dependências
    CREATE TABLE IF NOT EXISTS syncdt._dependencies (
        id SERIAL PRIMARY KEY,
        derived_schema TEXT NOT NULL,
        derived_table TEXT NOT NULL,
        source_schema TEXT NOT NULL,
        source_table TEXT NOT NULL,
		trigger_name text not null,
		target_columns text not null, 
		source_exp text not null,
        created_at TIMESTAMPTZ DEFAULT NOW(),
		index_names text,
		source_columns text
        FOREIGN KEY (derived_schema, derived_table) 
            REFERENCES syncdt._derived_tables(table_schema, table_name) ON DELETE CASCADE
    );
	
    CREATE INDEX IF NOT EXISTS idx_dependencies_derived ON syncdt._dependencies(derived_schema, derived_table);
    CREATE INDEX IF NOT EXISTS idx_dependencies_source ON syncdt._dependencies(source_schema, source_table);

    -- Tabela de fila de refresh
    CREATE TABLE IF NOT EXISTS syncdt._refresh_queue (
		id bigserial primary key,
		derived_schema TEXT NOT NULL,
		derived_table TEXT NOT NULL,		
		triggered_at TIMESTAMPTZ NOT NULL,
		filter text,
		--locked_by int,
		--locked_until TIMESTAMPTZ,
        processed_at TIMESTAMPTZ,
		wait_until TIMESTAMPTZ,
		source_schema text,
		source_table text,
		last_try timestamptz,
		last_error text
    );
    
    
--ALTER TABLE syncdt._refresh_queue ADD last_try timestamptz;

--ALTER TABLE syncdt._refresh_queue ADD last_error text;
    

	CREATE INDEX IF NOT EXISTS idx_refresh_queue_pending ON syncdt._refresh_queue(triggered_at, id) 
		WHERE processed_at IS NULL;
	CREATE INDEX IF NOT EXISTS idx_refresh_queue_locks ON syncdt._refresh_queue(locked_until) 
		WHERE locked_until IS NOT NULL;	
	CREATE INDEX IF NOT EXISTS idx_refresh_queue_locker ON syncdt._refresh_queue(triggered_at, id) 
		WHERE locked_by IS NOT NULL;	
	
    -- Tabela de logs
    CREATE TABLE IF NOT EXISTS syncdt._logs (
        id BIGSERIAL PRIMARY KEY,
        table_schema TEXT NULL,
        table_name TEXT NULL,
        command TEXT,
        started_at TIMESTAMPTZ NOT NULL,
        completed_at TIMESTAMPTZ,
        rows_affected BIGINT,
        success BOOLEAN,
        error_message TEXT
    );

    -- Índices para performance
    CREATE INDEX IF NOT EXISTS idx_logs_table ON syncdt._logs(table_schema, table_name);
    CREATE INDEX IF NOT EXISTS idx_logs_success ON syncdt._logs(success) WHERE success = false;

    RAISE NOTICE 'Tabelas internas do syncdt criadas com sucesso';
END;
$$;

perform syncdt._create_internal_tables();

