create schema if not exists syncdt;

CREATE OR REPLACE FUNCTION syncdt.create_derived_table(
    table_name TEXT,
    query TEXT,
    refresh_mode TEXT DEFAULT 'auto', --auto, deferred, immediate
    primary_key TEXT DEFAULT null,
    notification_mode text default 'optimized', --optimized, full
    processing_mode text default 'sequential' --sequential, grouped 
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    schema_name TEXT;
    base_table_name TEXT;
	squery text = query;
BEGIN
    -- Extrai schema e nome da tabela destino
    IF position('.' in table_name) > 0 THEN
        schema_name := split_part(table_name, '.', 1);
        base_table_name := split_part(table_name, '.', 2);
    ELSE
        schema_name := 'public';
        base_table_name := table_name;
    END IF;

    -- Validações iniciais
    IF schema_name IS NULL OR base_table_name IS NULL THEN
        RAISE EXCEPTION 'table_name inválido: %', table_name;
    END IF;

    -- Valida sintaxe da query
    PERFORM syncdt.test_query_syntax(query);

    -- Valida refresh_mode
    IF refresh_mode NOT IN ('auto', 'deferred', 'immediate') THEN
        RAISE EXCEPTION 'refresh_mode inválido: % (opções: auto, deferred ou immediate)', refresh_mode;
    END IF;

    -- Cria ou substitui a tabela derivada
    --EXECUTE format('DROP TABLE IF EXISTS %I.%I', schema_name, base_table_name);
    
	if refresh_mode in ('deferred', 'auto') then
		squery = format('select * from (%s) limit 0', query); 
	end if;

    -- Cria a tabela com ou sem PRIMARY KEY
    IF primary_key IS NOT NULL AND trim(primary_key) != '' THEN
        EXECUTE format('CREATE TABLE %I.%I (PRIMARY KEY (%s)) AS %s', schema_name, base_table_name, primary_key, squery);
    ELSE
        EXECUTE format('CREATE TABLE %I.%I AS %s', schema_name, base_table_name, squery);
    END IF;

    -- Registra metadados (sem source_tables_def)
    EXECUTE format('
        INSERT INTO syncdt._derived_tables (
            table_schema, table_name, definition_query, refresh_mode,
            primary_key, created_at, notification_mode, processing_mode
        ) VALUES (%L, %L, %L, %L, %L, NOW(), %L, %L);
    ', schema_name, base_table_name, query, refresh_mode, primary_key, notification_mode, processing_mode);

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


CREATE OR REPLACE FUNCTION syncdt._test_source_exp_syntax(
    source_exp text, source_table text)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    e TEXT;
BEGIN

	e = replace(source_exp, '${source}', '_t');
	e = format('SELECT %s FROM %s _t', e, source_table);
	PERFORM syncdt.test_query_syntax(e);

    RAISE notice 'source_exp syntax OK: %', source_exp;
    
 EXCEPTION
    WHEN OTHERS THEN
		raise notice '%', e;
        --RAISE EXCEPTION 'Erro de sintaxe na query: % (SQLSTATE: %)', SQLERRM, SQLSTATE;*/
		RAISE;
END; 
$$;



CREATE OR REPLACE FUNCTION syncdt.test_query_syntax(query TEXT)
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




CREATE OR REPLACE FUNCTION syncdt.assign_source_table(
    derived_table TEXT,
    source_table TEXT,
    target_columns TEXT,
    source_exp TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    d_schema TEXT;
    d_name TEXT;
    s_schema TEXT;
    s_name TEXT;
    trigger_name TEXT;
    rec RECORD;
BEGIN
    -- Extrai schema e nome da tabela derivada
    IF position('.' in derived_table) > 0 THEN
        d_schema := split_part(derived_table, '.', 1);
        d_name := split_part(derived_table, '.', 2);
    ELSE
        d_schema := 'public';
        d_name := derived_table;
    END IF;

    -- Extrai schema e nome da tabela fonte
    IF position('.' in source_table) > 0 THEN
        s_schema := split_part(source_table, '.', 1);
        s_name := split_part(source_table, '.', 2);
    ELSE
        s_schema := 'public';
        s_name := source_table;
    END IF;

    -- Valida se a tabela derivada existe nos metadados
    SELECT * INTO rec
    FROM syncdt._derived_tables
    WHERE table_schema = d_schema AND table_name = d_name;

	perform syncdt._test_source_exp_syntax(source_exp, source_table);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tabela derivada %.% não encontrada. Crie-a primeiro com syncdt.create_derived_table()',
                        d_schema, d_name;
    END IF;

    -- Verifica se já existe dependência
    /* SELECT * INTO rec
    FROM syncdt._dependencies d
    WHERE d.derived_schema = d_schema 
      AND d.derived_table = d_name
      AND d.source_schema = s_schema
      AND d.source_table = s_name;

    IF FOUND THEN
        RAISE WARNING 'Dependência já existe para %.% <- %.%, atualizando...',
                      d_schema, d_name, s_schema, s_name;
        
        IF rec.trigger_name IS NOT NULL THEN
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I',
                          rec.trigger_name, s_schema, s_name);
        END IF;
        
        DELETE FROM syncdt._dependencies d 
        WHERE d.derived_schema = d_schema 
          AND d.derived_table = d_name
          AND d.source_schema = s_schema
          AND d.source_table = s_name;
    END IF; */

    -- Cria trigger
    trigger_name := syncdt._create_refresh_trigger(
        d_schema, d_name, s_schema, s_name,	target_columns, source_exp
    );

    -- Registra dependência
    INSERT INTO syncdt._dependencies (
        derived_schema, derived_table, source_schema, source_table, target_columns, source_exp, trigger_name, created_at) 
		VALUES (d_schema, d_name, s_schema, s_name, target_columns, source_exp, trigger_name, NOW());

    RAISE NOTICE 'Source table %.% atribuída a %.% (trigger: %)',
                 s_schema, s_name, d_schema, d_name, trigger_name;
END;
$$;


CREATE OR REPLACE FUNCTION syncdt._create_refresh_trigger(
    derived_schema TEXT, derived_table TEXT,
    source_schema TEXT, source_name TEXT,
    target_columns text, source_exp text
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    trigger_name TEXT;
	rec record;
BEGIN
    -- Gera nome único para a trigger
    trigger_name := left(format('syncdt_%s_%s_%s', derived_table, source_schema, source_name), 63);

	select refresh_mode, notification_mode into rec
		from syncdt._derived_tables d
		where d.table_schema = $1 and d.table_name = $2;
    
    EXECUTE format('
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON %I.%I
        FOR EACH ROW
        EXECUTE FUNCTION syncdt._trigger_on_source_changed(%L, %L, %L, %L, %L, %L);',
        trigger_name, source_schema, source_name,
        derived_schema, derived_table, 
		rec.refresh_mode, rec.notification_mode,
		target_columns, source_exp
    );

	return trigger_name;
END;
$$;





CREATE OR REPLACE FUNCTION syncdt._trigger_on_source_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    derived_schema TEXT := TG_ARGV[0];
    derived_table TEXT := TG_ARGV[1];
	refresh_mode text := TG_ARGV[2];
	notification_mode text := TG_ARGV[3]; 
	target_columns TEXT := TG_ARGV[4];
	source_exp TEXT := TG_ARGV[5];
	expold text;
	expnew text;
BEGIN

	if TG_OP = 'DELETE' or TG_OP = 'UPDATE' then
		expold = replace(source_exp, '${source}', '$1');
		expold = syncdt._solve_record_expression(expold, OLD);
	end if;

	if TG_OP = 'INSERT' or TG_OP = 'UPDATE' then
		expnew = replace(source_exp, '${source}', '$1');
		expnew = syncdt._solve_record_expression(expnew, NEW);
	end if;

    IF TG_OP = 'DELETE' THEN
	    PERFORM syncdt._notify_source_changed(derived_schema, derived_table, refresh_mode, notification_mode, target_columns, expold);
    ELSIF TG_OP = 'INSERT' THEN
	    PERFORM syncdt._notify_source_changed(derived_schema, derived_table, refresh_mode, notification_mode, target_columns, expnew);
    ELSIF TG_OP = 'UPDATE' THEN
		if expold <> expnew then
		    PERFORM syncdt._notify_source_changed(derived_schema, derived_table, refresh_mode, notification_mode, target_columns, expold);
		    PERFORM syncdt._notify_source_changed(derived_schema, derived_table, refresh_mode, notification_mode, target_columns, expnew);
		end if;
    END IF;
    
    RETURN NULL;
END;
$$;






CREATE OR REPLACE FUNCTION syncdt._solve_record_expression(
    sql_exp text, 
    rec record
)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    values_array TEXT[];
    result TEXT := '';
    i INTEGER;
    fexp text;
BEGIN
	if sql_exp is null then
		raise exception 'Expressão SQL nula';
	end if;

    -- O SQL traz $1. como referência ao registro
    --sql_parsed := replace(sql_exp, 'rec.', '$1.');
    
    -- Constrói a query com placeholder
    fexp := format('SELECT ARRAY[%s]::TEXT[]', sql_exp);
    
    -- Executa passando o registro como parâmetro
    EXECUTE fexp INTO values_array USING rec;
    
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
$function$;




---REMOVER!!!!!!!!!!!!!!!!!
-- Função auxiliar que recebe OLD e NEW explicitamente
CREATE OR REPLACE drop FUNCTION syncdt._solve_trigger_expression(
    sql_exp TEXT,
    old_row RECORD,
    new_row RECORD
) RETURNS TEXT AS $$
DECLARE
    values_array TEXT[];
    result TEXT := '';
    i INTEGER;
	fexp text;
BEGIN
    -- Executa usando os parâmetros recebidos
	fexp = format('SELECT ARRAY[%s]::TEXT[]', sql_exp);
	
    EXECUTE fexp
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



CREATE OR REPLACE FUNCTION syncdt._notify_source_changed(
    derived_schema TEXT,
    derived_table TEXT,
    refresh_mode text,
    notification_mode text,
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
	if notification_mode = 'optimized' then

		INSERT INTO syncdt._refresh_queue (derived_schema, derived_table, triggered_at, filter)
			SELECT $1, $2, NOW(), filter
		WHERE NOT EXISTS (SELECT 1 FROM syncdt._refresh_queue q
		    WHERE q.derived_schema = $1 AND q.derived_table = $2 AND q.filter = $3 AND q.processed_at IS NULL);

	elsif notification_mode = 'full' then

	    INSERT INTO syncdt._refresh_queue (derived_schema, derived_table, triggered_at, filter)
	    VALUES ($1, $2, NOW(), filter);

	else
		raise exception 'Modo de notificação desconhecido: %', notification_mode;
	end if;

    IF refresh_mode = 'immediate' THEN
        PERFORM syncdt.update_changes(derived_schema, derived_table);

    ELSIF refresh_mode = 'auto' THEN
        c := syncdt.pending_refresh_cost(derived_schema, derived_table);
        
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
    source_exp TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    filter TEXT;
BEGIN
    filter := format('(%s) = (%s)', target_columns, source_exp);    
    RETURN filter;
END;
$$;



CREATE OR REPLACE FUNCTION syncdt.pending_refresh_cost(
    derived_schema TEXT,
    derived_table TEXT
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




CREATE OR REPLACE FUNCTION syncdt._refresh_derived_table(
	derived_schema text,
    derived_table TEXT,
    filter text default null
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
	q text;
	w text;
BEGIN
	select definition_query into q from syncdt._derived_tables d
		where d.table_schema = $1 and table_name = $2;

	if filter is null then
		w = '';
	else
		w = 'where ' || filter;
	end if;
		
    EXECUTE format('INSERT INTO %I.%I select * from (%s) %s', derived_schema, derived_table, q, w);
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




CREATE OR REPLACE FUNCTION syncdt.update_changes(
    derived_schema TEXT,
    derived_table TEXT,
    max_queue int default null
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
	mode text;
BEGIN
	select processing_mode into mode
	from syncdt._derived_tables d 
	where d.derived_schema = $1 and d.derived_table = $2;

	if mode = 'sequential' then
		perform syncdt.update_changes_sequential(derived_schema, derived_table, max_queue);
	elsif mode = 'grouped' then
		perform syncdt.update_changes_grouped(derived_schema, derived_table, max_queue);
	end if;

	raise exception 'Modo de processamento desconhecido: %', mode;
END;
$$;







CREATE OR REPLACE FUNCTION syncdt._update_changes_sequential(
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
	pid int;
BEGIN
    start_time := NOW();
	pid = pg_backend_pid();

	update syncdt._refresh_queue
	set locked_by = pid, locked_until = start_time + interval '5 minutes'
    WHERE id in 
		(SELECT id 
	     FROM syncdt._refresh_queue
		 where processed_at is null
		   AND ((derived_schema = $1 AND derived_table = $2) OR
			   ($1 is null AND $2 is null))
		   and (locked_by is null or locked_by = pid or locked_until < now() or locked_until is null)		      		
	     ORDER BY triggered_at, id ASC
	     limit max_queue);


    -- FASE 1: DELETE de todos os pendentes (um por um)
    FOR rec IN
        SELECT * 
        FROM syncdt._refresh_queue
        WHERE locked_by = pid
        ORDER BY triggered_at, id ASC
    LOOP
        EXECUTE format('DELETE FROM %I.%I WHERE %s', 
                       derived_schema, derived_table, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;
		filter_count = filter_count + 1; 
    END LOOP;
    
    -- FASE 2: INSERT de todos os pendentes (um por um)
    FOR rec IN
        SELECT * 
        FROM syncdt._refresh_queue
        WHERE locked_by = pid
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
	    SET processed_at = NOW(), locked_at = null, locked_until = null
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




CREATE OR REPLACE FUNCTION syncdt._update_changes_grouped(
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
	pid int;
BEGIN
    start_time := NOW();
	pid = pg_backend_pid();

	update syncdt._refresh_queue
	set locked_by = pid, locked_until = start_time + interval '5 minutes'
    WHERE id in 
		(SELECT id 
	     FROM syncdt._refresh_queue
		 where processed_at is null
		   AND ((derived_schema = $1 AND derived_table = $2) OR
			   ($1 is null AND $2 is null))
		   and (locked_by is null or locked_by = pid or locked_until < now() or locked_until is null)		      		
	     ORDER BY triggered_at, id ASC
	     limit max_queue);


    -- FASE 1: DELETE de todos os pendentes (um por um)
    FOR rec IN
		select 	derived_schema, derived_table, 
				string_agg(filter, ' OR ') as filter, 
				array_agg(id) as ids,
				count(*) as row_count
		from (
	        SELECT * 
	        FROM syncdt._refresh_queue
	        WHERE locked_by = pid
	        ORDER BY triggered_at, id ASC
		) group by derived_schema, derived_table
    LOOP
		filter_count = rec.row_count;

        EXECUTE format('DELETE FROM %I.%I WHERE %s', 
                       derived_schema, derived_table, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;

	    SELECT definition_query INTO query
	    FROM syncdt._derived_tables d
	    WHERE (d.derived_schema = rec.derived_schema AND d.derived_table = rec.derived_table);

        EXECUTE format('INSERT INTO %I.%I %s AND %s',
                       derived_schema, derived_table, query, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;

    -- Marca como processado
	    UPDATE syncdt._refresh_queue 
	    SET processed_at = NOW(), locked_at = null, locked_until = null
	    WHERE id = any(rec.ids);

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
        INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        VALUES (schema_name, base_table_name, 'DROP', start_time, NOW(), false, 
                format('Tabela derivada %s.%s não encontrada nos metadados', schema_name, base_table_name));
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








select * from syncdt._derived_tables





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
	    primary_key TEXT,
	    created_at TIMESTAMPTZ NOT NULL,
	    updated_at TIMESTAMPTZ DEFAULT NOW(),
	    notification_mode text default 'optimized', --optimized, full
    	processing_mode text default 'sequential', --sequential, grouped 
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
	
    CREATE INDEX IF NOT EXISTS idx_dependencies_derived ON syncdt._dependencies(derived_schema, derived_table);
    CREATE INDEX IF NOT EXISTS idx_dependencies_source ON syncdt._dependencies(source_schema, source_table);

    -- Tabela de fila de refresh
    CREATE TABLE IF NOT EXISTS syncdt._refresh_queue (
		id bigserial primary key,
		derived_schema TEXT NOT NULL,
		derived_table TEXT NOT NULL,		
		triggered_at TIMESTAMPTZ NOT NULL,
		filter text,
		locked_by int,
		locked_until TIMESTAMPTZ,
        processed_at TIMESTAMPTZ
    );

	CREATE INDEX IF NOT EXISTS idx_refresh_queue_pending ON syncdt._refresh_queue(triggered_at, id) 
		WHERE processed_at IS NULL;
	CREATE INDEX IF NOT EXISTS idx_refresh_queue_locks ON syncdt._refresh_queue(locked_until) 
		WHERE locked_until IS NOT NULL;	
	CREATE INDEX IF NOT EXISTS idx_refresh_queue_locker ON syncdt._refresh_queue(triggered_at, id) 
		WHERE locked_by IS NOT NULL;	
	
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
	table_name => 'tlm.resumo_leituras_tag_dia',
	query => 'select * from tlm.gerar_resumo_leituras_tag_dia',
	refresh_mode => 'auto'
);


select syncdt.assign_source_table(
		derived_table => 'tlm.resumo_leituras_tag_dia',
		source_table => 'tlm.leitura_tag',
		target_columns => 'dia, tag_id',
		source_exp => 'dref(${source}.diahora), ${source}.tag'
);


--select syncdt.refresh_derived_table('tlm.resumo_leituras_tag_dia');




select syncdt._test_source_exp_syntax('dref(${source}.diahora), ${source}.tag', 'tlm.leitura_tag');



--select * from tlm.leitura_tag

--select * from tlm.resumo_leituras_tag_dia


--DROP TRIGGER IF EXISTS syncdt_resumo_leituras_tag_dia_tlm_leitura_tag ON tlm.leitura_tag;

--select syncdt.drop_derived_table('tlm.resumo_leituras_tag_dia')



