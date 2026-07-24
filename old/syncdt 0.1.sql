create schema if not exists syncdt;

CREATE OR REPLACE FUNCTION syncdt.create_derived_table(
    table_name TEXT,
    query TEXT,
    source_tables JSONB,
    refresh_mode TEXT DEFAULT 'auto',
    primary_key TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    source_tables_array JSONB;
    source_item JSONB;
    schema_name TEXT;
    base_table_name TEXT;
BEGIN
    -- 1. Normaliza source_tables: objeto vira array de 1 ou n elementos
    IF jsonb_typeof(source_tables) = 'object' THEN
        source_tables_array := jsonb_build_array(source_tables);
    ELSIF jsonb_typeof(source_tables) = 'array' THEN
        source_tables_array := source_tables;
    ELSE
        RAISE EXCEPTION 'source_tables deve ser um objeto ou array, recebido: %', jsonb_typeof(source_tables);
    END IF;

    -- 2. Extrai schema e nome da tabela destino
    IF position('.' in table_name) > 0 THEN
        schema_name := split_part(table_name, '.', 1);
        base_table_name := split_part(table_name, '.', 2);
    ELSE
        schema_name := 'public';
        base_table_name := table_name;
    END IF;

    -- 3. Validações iniciais
    IF schema_name IS NULL OR base_table_name IS NULL THEN
        RAISE EXCEPTION 'table_name inválido: %', table_name;
    END IF;

    -- Valida sintaxe da query
    PERFORM syncdt.test_query_syntax(query);

    -- Valida refresh_mode
    IF refresh_mode NOT IN ('auto', 'deferred', 'immediate') THEN
        RAISE EXCEPTION 'refresh_mode inválido: % (opções: auto, deferred ou immediate)', refresh_mode;
    END IF;

    -- 4. Valida cada tabela fonte
    FOR source_item IN SELECT * FROM jsonb_array_elements(source_tables_array)
    LOOP
        PERFORM syncdt._validate_source_table(source_item);
    END LOOP;

    -- 5. Cria ou substitui a tabela derivada (sem CASCADE)
    EXECUTE format('DROP TABLE IF EXISTS %I.%I', schema_name, base_table_name);
    
    -- Cria a tabela com ou sem PRIMARY KEY
    IF primary_key IS NOT NULL AND trim(primary_key) != '' THEN
        EXECUTE format('
            CREATE TABLE %I.%I (
                PRIMARY KEY (%s)
            ) AS %s',
            schema_name, base_table_name, primary_key, query
        );
    ELSE
        EXECUTE format('CREATE TABLE %I.%I AS %s', 
                       schema_name, base_table_name, query);
    END IF;

    -- 6. Registra metadados
    EXECUTE format('
        INSERT INTO syncdt._derived_tables (
            table_schema,
            table_name,
            definition_query,
            refresh_mode,
            source_tables_def,
            primary_key,
            created_at
        ) VALUES (%L, %L, %L, %L, %L, %L, NOW())
        ON CONFLICT (table_schema, table_name) 
        DO UPDATE SET
            definition_query = EXCLUDED.definition_query,
            refresh_mode = EXCLUDED.refresh_mode,
            source_tables_def = EXCLUDED.source_tables_def,
            primary_key = EXCLUDED.primary_key,
            updated_at = NOW()
    ', schema_name, base_table_name, query, refresh_mode, source_tables, primary_key);

    -- 7. Configura cada source_table
    FOR source_item IN SELECT * FROM jsonb_array_elements(source_tables_array)
    LOOP
        PERFORM syncdt._assign_source_table(
            schema_name,
            base_table_name,
            source_item->>'table_name',
            source_item->>'target_columns',
            source_item->>'source_exp'
        );
    END LOOP;

    -- 8. Configura refresh automático se for 'auto'
    IF refresh_mode = 'auto' THEN
        PERFORM syncdt._setup_auto_refresh(schema_name, base_table_name);
    END IF;

    RAISE NOTICE 'Tabela derivada %.% criada com sucesso (modo: %, pk: %)', 
                 schema_name, base_table_name, refresh_mode, COALESCE(primary_key, 'nenhuma');
END;
$$;





CREATE OR REPLACE FUNCTION syncdt.check_table_exists(
    table_full_name TEXT, raise_error boolean default true
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    schema_name TEXT;
    table_name TEXT;
    table_exists BOOLEAN;
BEGIN
    IF position('.' in table_full_name) > 0 THEN
        schema_name := split_part(table_full_name, '.', 1);
        table_name := split_part(table_full_name, '.', 2);
    ELSE
        schema_name := 'public';
        table_name := table_full_name;
    END IF;
    
    SELECT EXISTS (
        SELECT 1 
        FROM information_schema.tables 
        WHERE table_schema = schema_name 
          AND table_name = table_name
    ) INTO table_exists;
    
    IF NOT table_exists THEN
		if raise_error then
        	RAISE EXCEPTION 'Tabela não existe: %.%', schema_name, table_name;
		else
			return false;
		end if;
    END IF;
    
    RETURN table_exists;
END;
$$;






CREATE OR REPLACE FUNCTION syncdt.test_query_syntax(
    query TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    test_sql TEXT;
BEGIN
    -- Validação básica
    IF query IS NULL OR trim(query) = '' THEN
        RAISE EXCEPTION 'Query não pode ser vazia';
    END IF;
    
    -- Constrói SQL de teste com LIMIT 0
    test_sql := format('SELECT * FROM (%s) AS _ LIMIT 0', query);
    
    -- Executa o teste (apenas validação sintática e semântica)
    EXECUTE test_sql;
    
    RAISE DEBUG 'Query syntax OK: %', left(query, 100);
    
EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Erro de sintaxe na query: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
END;
$$;




CREATE OR REPLACE FUNCTION syncdt._validate_source_table(
    source_item JSONB
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    source_table_full TEXT;
    map_columns TEXT;
BEGIN
    source_table_full := source_item->>'table_name';
    map_columns := source_item->>'map_columns';
    
    -- Valida table_name obrigatório
    IF source_table_full IS NULL THEN
        RAISE EXCEPTION 'cada source_table deve ter "table_name"';
    END IF;
    
    -- Valida se a tabela fonte existe
    PERFORM syncdt.check_table_exists(source_table_full);
    
    -- Valida map_columns (se fornecido)
    IF map_columns IS NOT NULL AND map_columns NOT LIKE '%${source}%' THEN
        RAISE WARNING 'map_columns não contém ${source}: %', map_columns;
    END IF;
END;
$$;




CREATE OR REPLACE FUNCTION syncdt._assign_source_table(
    derived_schema TEXT,
    derived_table TEXT,
    source_table_full TEXT,
	target_columns text,
    source_exp text
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    source_schema TEXT;
    source_name TEXT;
	trigger_name text;
BEGIN
    -- Extrai schema e nome da tabela fonte
    IF position('.' in source_table_full) > 0 THEN
        source_schema := split_part(source_table_full, '.', 1);
        source_name := split_part(source_table_full, '.', 2);
    ELSE
        source_schema := 'public';
        source_name := source_table_full;
    END IF;

    -- Cria trigger
	trigger_name = syncdt._create_refresh_trigger(derived_schema, derived_table, source_schema, source_name); 	

    -- Registra dependência
    INSERT INTO syncdt._dependencies (derived_schema, derived_table, source_schema, source_table, target_columns, source_exp, trigger_name) 
    VALUES (derived_schema, derived_table, source_schema, source_name, target_columns, source_exp, trigger_name);

    RAISE DEBUG 'Source table %.% atribuída a %.%', 
                source_schema, source_name, derived_schema, derived_table;
END;
$$;



CREATE OR REPLACE FUNCTION syncdt._create_refresh_trigger(
    derived_schema TEXT,
    derived_table TEXT,
    source_schema TEXT,
    source_name TEXT    
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    trigger_name TEXT;
BEGIN
    -- Gera nome único para a trigger
    trigger_name := left(format('syncdt_%s_%s_%s', derived_table, source_schema, source_name), 63);
    
    EXECUTE format('
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON %I.%I
        FOR EACH ROW
        EXECUTE FUNCTION syncdt._trigger_on_source_changed(%L, %L, %L, %L, %L);',
        trigger_name,
        source_schema,
        source_name,
        derived_schema,
        derived_table,
		refresh_mode,
		target_columns,
		source_exp							
    );
    
    -- Registra a trigger
    INSERT INTO syncdt._triggers (trigger_name, derived_schema, derived_table, source_schema, source_table)
    	VALUES (trigger_name, derived_schema, derived_table, source_schema, source_name);

	return trigger_name;
END;
$$;




-- Função auxiliar que recebe OLD e NEW explicitamente
CREATE OR REPLACE FUNCTION syncdt._solve_trigger_expression(
    sql_exp TEXT,
    old_row RECORD,
    new_row RECORD
) RETURNS TEXT AS $$
DECLARE
    values_array TEXT[];
    result TEXT := '';
    i INTEGER;
BEGIN
    -- Executa usando os parâmetros recebidos
    EXECUTE format('SELECT ARRAY[%s]::TEXT[]', sql_exp) 
        INTO values_array 
        USING old_row, new_row;
    
    -- Formata o resultado
    FOR i IN 1 .. array_length(values_array, 1) LOOP
        IF i > 1 THEN
            result := result || ', ';
        END IF;
        
        IF values_array[i] IS NULL OR values_array[i] = 'NULL' THEN
            result := result || 'NULL';
        ELSIF values_array[i] ~ '^-?\d+(\.\d+)?$' THEN
            result := result || values_array[i];
        ELSIF values_array[i] IN ('t', 'f', 'true', 'false') THEN
            result := result || values_array[i];
        ELSE
            result := result || quote_literal(values_array[i]);
        END IF;
    END LOOP;
    
    RETURN result;
END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION syncdt._trigger_on_source_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    derived_schema TEXT := TG_ARGV[0];
    derived_table TEXT := TG_ARGV[1];
	refresh_mode text := TG_ARGV[2];
	target_columns TEXT := TG_ARGV[3];
	source_exp TEXT := TG_ARGV[4];
	nold boolean = false;
	nnew boolean = true;
	exp text;
BEGIN
    IF TG_OP = 'DELETE' THEN
		nold = true;
    ELSIF TG_OP = 'INSERT' THEN
		nnew = true;
    ELSIF TG_OP = 'UPDATE' THEN
		nold = true;
		nnew = true;
    END IF;

	if nnold then
		exp = replace(source_exp, '${source}', 'OLD');
		exp = syncdt._solve_trigger_expression(exp, OLD, NEW);
	    PERFORM syncdt._notify_source_changed(derived_schema, derived_table, refresh_mode, target_columns, exp);
	end if;

	if nnew then
		exp = replace(source_exp, '${source}', 'NEW');
		exp = syncdt._solve_trigger_expression(exp, OLD, NEW);
	    PERFORM syncdt._notify_source_changed(derived_schema, derived_table, refresh_mode, target_columns, exp);
	end if;
    
    RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION syncdt._notify_source_changed(
    derived_schema TEXT,
    derived_table TEXT,
    refresh_mode text,
    target_columns text, 
    source_exp text
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    drec RECORD;
    filter TEXT;
    c FLOAT;
BEGIN
    -- Constrói o filter usando o column_mapping
    filter := syncdt._build_filter(target_columns, source_exp);
    
    -- Enfileira o refresh
    INSERT INTO syncdt._refresh_queue (derived_schema, derived_table, triggered_at, filter, pending)
    VALUES (derived_schema, derived_table, NOW(), filter, true);
    
    RAISE DEBUG 'Refresh enfileirado para %.% (modo: %, filter: %)', 
                derived_schema, derived_table, drec.refresh_mode, filter;

    IF refresh_mode = 'immediate' THEN
        PERFORM syncdt.update_changes(derived_schema, derived_table);

    ELSIF refresh_mode = 'auto' THEN
        c := syncdt.pending_refresh_cost(derived_schema, derived_table, source_schema, source_table);
        
        IF c > 0.7 * syncdt.total_cost(derived_schema, derived_table) THEN	 
            PERFORM syncdt.update_changes(derived_schema, derived_table);
        END IF;
    ELSIF refresh_mode = 'deferred' THEN
		--Não precisa fazer nada. As notificações vão automaticamente preencher a tabela de notificações.
    END IF;
END;
$$;


CREATE OR REPLACE FUNCTION syncdt._build_filter(
    target_columns TEXT,
    source_exp TEXT,
    source_schema TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    source_full TEXT;
    expanded_source TEXT;
    filter TEXT;
BEGIN
    filter := format('(%s) = (%s)', target_columns, source_exp);    
    RETURN filter;
END;
$$;



CREATE OR REPLACE FUNCTION syncdt.pending_refresh_cost(
    derived_schema TEXT,
    derived_table TEXT,
    source_schema TEXT,
    source_table TEXT
)
RETURNS FLOAT
LANGUAGE plpgsql
AS $$
DECLARE
    filter TEXT;
    source_count BIGINT;
    pending_count BIGINT;
    cost FLOAT;
BEGIN
	return 0.0; --temporário
    /*
    -- Busca o filter pendente
    SELECT filter INTO filter
    FROM syncdt._refresh_queue
    WHERE derived_schema = derived_schema AND derived_table = derived_table
      AND pending = true
    ORDER BY triggered_at DESC
    LIMIT 1;
    
    -- Se não há filter, considera custo total
    IF filter IS NULL OR filter = '' THEN
        RETURN 1.0;
    END IF;
    
    -- Conta quantas linhas na tabela fonte seriam afetadas pelo filter
    EXECUTE format('SELECT COUNT(*) FROM %I.%I WHERE %s', 
                   source_schema, source_table, filter)
    INTO pending_count;
    
    -- Conta total de linhas na tabela fonte
    EXECUTE format('SELECT COUNT(*) FROM %I.%I', source_schema, source_table)
    INTO source_count;
    
    -- Custo = proporção de linhas afetadas / total
    IF source_count > 0 THEN
        cost := pending_count::FLOAT / source_count::FLOAT;
    ELSE
        cost := 0;
    END IF;
    
    RETURN cost; */
END;
$$;



CREATE OR REPLACE FUNCTION syncdt.total_cost(
    derived_schema TEXT,
    derived_table TEXT
)
RETURNS FLOAT
LANGUAGE plpgsql
AS $$
DECLARE
    source_count BIGINT;
    derived_count BIGINT;
    cost FLOAT;
BEGIN
	return 100000; --temporário
	/*
    -- Busca a primeira dependência (assumindo que a principal fonte é a primeira)
    -- Ou você pode somar custos de todas as fontes
    SELECT COUNT(*) INTO source_count
    FROM syncdt._dependencies d
    CROSS JOIN LATERAL (
        EXECUTE format('SELECT COUNT(*) FROM %I.%I', d.source_schema, d.source_table)
    ) AS s(cnt)
    WHERE d.derived_schema = derived_schema AND d.derived_table = derived_table
    LIMIT 1;
    
    -- Conta linhas na tabela derivada atual
    EXECUTE format('SELECT COUNT(*) FROM %I.%I', derived_schema, derived_table)
    INTO derived_count;
    
    -- Custo baseado no tamanho da maior tabela fonte ou na derivada
    cost := GREATEST(source_count, derived_count)::FLOAT / 10000; -- normalizado
    
    -- Limita entre 0 e 1
    IF cost > 1 THEN
        cost := 1;
    ELSIF cost < 0 THEN
        cost := 0;
    END IF;
    
    RETURN cost; */
END;
$$;





CREATE OR REPLACE FUNCTION syncdt.update_changes(
    derived_schema TEXT,
    derived_table TEXT,
    max_queue int default null
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    query TEXT;
    rec RECORD;
    start_time TIMESTAMPTZ;
    rows_affected BIGINT;
    total_deleted BIGINT := 0;
    total_inserted BIGINT := 0;
    filter_count INTEGER := 0;
BEGIN
    start_time := NOW();
    
    -- FASE 1: DELETE de todos os pendentes (um por um)
    FOR rec IN
        SELECT * 
        FROM syncdt._refresh_queue
        WHERE pending = true
		  AND ((derived_schema = $1 AND derived_table = $2) OR
		   ($1 is null AND $2 is null))
        ORDER BY triggered_at, id ASC
    LOOP
        EXECUTE format('DELETE FROM %I.%I WHERE %s', 
                       derived_schema, derived_table, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;
    END LOOP;
    
    -- FASE 2: INSERT de todos os pendentes (um por um)
    FOR rec IN
        SELECT * 
        FROM syncdt._refresh_queue
        WHERE pending = true
		  AND ((derived_schema = $1 AND derived_table = $2) OR
		   ($1 is null AND $2 is null))          
        ORDER BY triggered_at, id ASC
    LOOP
	    SELECT definition_query INTO query
	    FROM syncdt._derived_tables d
	    WHERE (d.derived_schema = rec.derived_schema AND d.derived_table = rec.derived_table);

        EXECUTE format('INSERT INTO %I.%I %s AND %s',
                       derived_schema, derived_table, query, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_inserted := total_inserted + rows_affected;

    -- Marca como processado
	    UPDATE syncdt._refresh_queue 
	    SET pending = false, processed_at = NOW()
	    WHERE id = rec.id;
    END LOOP;
    
    
    -- Log de sucesso
    INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, rows_affected, success)
    VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), total_inserted, true);
    
    RAISE NOTICE 'Refresh concluído para %.% (deletados: %, inseridos: %, filters: %)', 
                 $1, $2, total_deleted, total_inserted, filter_count;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log do erro
        INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), false, SQLERRM);
        
        RAISE WARNING 'Erro no refresh de %.%: %', derived_schema, derived_table, SQLERRM;
        RAISE;
END;
$$;




CREATE OR REPLACE FUNCTION syncdt.update_changes(
    max_queue int default null
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
BEGIN
	perform syncdt.update_changes(null, null, max_queue);
END;
$$;






CREATE OR REPLACE FUNCTION syncdt.drop_derived_table(
    table_name TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    schema_name TEXT;
    base_table_name TEXT;
    metadata_record RECORD;
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
    SELECT * INTO metadata_record
    FROM syncdt._derived_tables
    WHERE table_schema = schema_name AND table_name = base_table_name;

    IF NOT FOUND THEN
        INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), false, 
                format('Tabela derivada %.% não encontrada nos metadados', schema_name, base_table_name));
        RAISE EXCEPTION 'Tabela derivada %.% não encontrada nos metadados', schema_name, base_table_name;
    END IF;

    -- Remove triggers
    PERFORM syncdt._drop_auto_refresh_triggers(schema_name, base_table_name);

    -- Remove dependências e metadados
    DELETE FROM syncdt._dependencies WHERE derived_schema = schema_name AND derived_table = base_table_name;
    DELETE FROM syncdt._derived_tables WHERE table_schema = schema_name AND table_name = base_table_name;

    -- Remove a tabela física
    EXECUTE format('DROP TABLE IF EXISTS %I.%I CASCADE', schema_name, base_table_name);

    -- Log de sucesso
    INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success)
    VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), true);

    RAISE NOTICE 'Tabela derivada %.% removida com sucesso', schema_name, base_table_name;

EXCEPTION
    WHEN OTHERS THEN
        INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), false, SQLERRM);
        RAISE;
END;
$$;






CREATE OR REPLACE FUNCTION syncdt._create_internal_tables()
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
	    source_tables_def JSONB NOT NULL,
	    primary_key TEXT,                    -- novo campo
	    created_at TIMESTAMPTZ NOT NULL,
	    updated_at TIMESTAMPTZ DEFAULT NOW(),
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
        FOREIGN KEY (derived_schema, derived_table) 
            REFERENCES syncdt._derived_tables(table_schema, table_name) ON DELETE CASCADE
    );

    -- Tabela de fila de refresh
    CREATE TABLE IF NOT EXISTS syncdt._refresh_queue (
		id bigserial primary key,
        derived_schema TEXT NOT NULL,
        derived_table TEXT NOT NULL,
        triggered_at TIMESTAMPTZ NOT NULL,
        pending BOOLEAN DEFAULT true,
        processed_at TIMESTAMPTZ
    );

    -- Tabela de logs
    CREATE TABLE IF NOT EXISTS syncdt._logs (
        id BIGSERIAL PRIMARY KEY,
        table_schema TEXT NOT NULL,
        table_name TEXT NOT NULL,
        command TEXT,
        started_at TIMESTAMPTZ NOT NULL,
        completed_at TIMESTAMPTZ,
        rows_affected BIGINT,
        success BOOLEAN,
        error_message TEXT
    );

    -- Índices para performance
    CREATE INDEX IF NOT EXISTS idx_dependencies_derived ON syncdt._dependencies(derived_schema, derived_table);
    CREATE INDEX IF NOT EXISTS idx_dependencies_source ON syncdt._dependencies(source_schema, source_table);
    CREATE INDEX IF NOT EXISTS idx_refresh_queue_pending ON syncdt._refresh_queue(derived_schema, derived_table, id) WHERE pending = true;
    CREATE INDEX IF NOT EXISTS idx_refresh_queue_pending2 ON syncdt._refresh_queue(derived_schema, derived_table, triggered_at) WHERE pending = true;
    CREATE INDEX IF NOT EXISTS idx_logs_table ON syncdt._logs(table_schema, table_name);
    CREATE INDEX IF NOT EXISTS idx_logs_success ON syncdt._logs(success) WHERE success = false;

    RAISE NOTICE 'Tabelas internas do syncdt criadas com sucesso';
END;
$$;







CREATE OR REPLACE FUNCTION syncdt._drop_internal_tables()
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    -- Remove índices explicitamente (opcional, CASCADE já remove)
    DROP INDEX IF EXISTS syncdt.idx_dependencies_derived;
    DROP INDEX IF EXISTS syncdt.idx_dependencies_source;
    DROP INDEX IF EXISTS syncdt.idx_triggers_derived;
    DROP INDEX IF EXISTS syncdt.idx_triggers_source;
    DROP INDEX IF EXISTS syncdt.idx_refresh_queue_pending;
    DROP INDEX IF EXISTS syncdt.idx_logs_table;
    DROP INDEX IF EXISTS syncdt.idx_logs_success;
    
    -- Remove as tabelas (CASCADE cuida das dependências)
    DROP TABLE IF EXISTS syncdt._logs CASCADE;
    DROP TABLE IF EXISTS syncdt._refresh_queue CASCADE;
    DROP TABLE IF EXISTS syncdt._dependencies CASCADE;
    DROP TABLE IF EXISTS syncdt._derived_tables CASCADE;
    
    RAISE NOTICE 'Tabelas internas do syncdt removidas com sucesso';
END;
$$;




----------------------------------------------------------------------------------------------------------------



select syncdt.create_derived_table(
	table_name => 'tlm.resumo_leituras_tag_hora',  --schema é opcional
	query => 'select * from tlm.gerar_resumo_leituras_tag_hora',
	refresh_mode => 'auto',              --opções: {auto, deferred, immediate}'
	source_tables => $$
		table_name => 'tlm.leitura_tag',
		target_columns => 'diahora_ref, tag'
		source_exp => '${source}.diahora, ${source}.tag' 
	$$	
)


select *
from tlm.leitura_tag
