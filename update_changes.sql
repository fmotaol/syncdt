
CREATE OR REPLACE FUNCTION syncdt._update_changes(
    derived_schema TEXT,
    derived_table TEXT,
	mode text default 'sequential',
    max_queue int default null
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
BEGIN
	if mode = 'sequential' then
		perform syncdt._update_changes_sequential(derived_schema, derived_table, max_queue);
	elsif mode = 'grouped' then
		perform syncdt._update_changes_grouped(derived_schema, derived_table, max_queue);
	else
		raise exception 'Modo de processamento desconhecido: %', mode;
	end if;

END;
$$;






CREATE OR REPLACE FUNCTION syncdt._getConfig(
    varname TEXT,
    default_value ANYELEMENT DEFAULT NULL
)
RETURNS ANYELEMENT AS $$
DECLARE
BEGIN
	if not syncdt.check_table_exists('syncdt._configs', false) then
		if varname = 'keep_queue_history_days' then
			return 30;
		end if;	
	end if;
END;
$$ LANGUAGE plpgsql;








CREATE OR REPLACE FUNCTION syncdt._clear_queue_history()
RETURNS VOID AS $$
DECLARE
	days int;
BEGIN
	days = syncdt._getConfig('keep_queue_history_days', 30);

	delete from syncdt._refresh_queue
	where processed_at < now()::date - (days || ' days')::interval;
END;
$$ LANGUAGE plpgsql;






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
    pid int;
    st text;
    job_count INTEGER;
    error_count INTEGER := 0;
BEGIN
	perform syncdt._clear_queue_history();

    start_time := NOW();
    pid = pg_backend_pid();

    -- 📦 PASSO 1: Cria tabela temporária para os jobs
    -- Mantém a mesma estrutura da _refresh_queue + campo de status
    CREATE TEMP TABLE temp_jobs_to_process (
        id INTEGER PRIMARY KEY,
        derived_schema TEXT,
        derived_table TEXT,
        filter TEXT,
        triggered_at TIMESTAMPTZ,
        wait_until TIMESTAMPTZ,
        processed_at TIMESTAMPTZ,
        status TEXT DEFAULT 'Pending',  -- pending, processing, done, error
        error_message TEXT
    ) ON COMMIT DROP;

    -- 🔒 PASSO 2: Pega os jobs com lock e insere na temp table
    -- O lock só existe durante este INSERT
    INSERT INTO temp_jobs_to_process (
        id, derived_schema, derived_table, filter, 
        triggered_at, wait_until, processed_at
    )
    SELECT 
        q.id, q.derived_schema, q.derived_table, q.filter,
        q.triggered_at, q.wait_until, q.processed_at
    FROM syncdt._refresh_queue q
    WHERE processed_at is null
      AND ((q.derived_schema = _update_changes_sequential.derived_schema AND q.derived_table = _update_changes_sequential.derived_table) OR
           (_update_changes_sequential.derived_schema is null AND _update_changes_sequential.derived_table is null))
      AND (q.wait_until is null or q.wait_until <= NOW())
    ORDER BY triggered_at, id ASC
    LIMIT max_queue
    FOR UPDATE SKIP LOCKED;

    -- 🔓 Lock liberado automaticamente aqui!

    GET DIAGNOSTICS job_count = ROW_COUNT;
    
    IF job_count = 0 THEN
        --RAISE NOTICE 'Nenhuma atualização disponível para processar';
        RETURN;
    END IF;

    --RAISE NOTICE '🔒 Worker %: Pegou % jobs e liberou os locks', pid, job_count;

    -- 📦 PASSO 3: Processa os jobs da tabela temporária
    -- Agora podemos processar SEM LOCKS na _refresh_queue!
    FOR rec IN 
        SELECT * FROM temp_jobs_to_process 
        WHERE status = 'Pending'
        ORDER BY triggered_at, id ASC
    LOOP
        BEGIN
            -- Atualiza status na temp table
            UPDATE temp_jobs_to_process 
            SET status = 'Processing' 
            WHERE id = rec.id;

            -- Pega a query de definição
            SELECT definition_query INTO query
            FROM syncdt._derived_tables d
            WHERE d.table_schema = rec.derived_schema 
              AND d.table_name = rec.derived_table;

            IF NOT FOUND OR query IS NULL THEN
                RAISE EXCEPTION 'definition_query não encontrada para %.%', 
                               rec.derived_schema, rec.derived_table;
            END IF;

            -- DELETE + INSERT (pode demorar, SEM LOCKS na _refresh_queue!)
            PERFORM syncdt.execute('DELETE FROM %I.%I WHERE %s',
                                  rec.derived_schema, rec.derived_table, rec.filter);
            
            PERFORM syncdt.execute('INSERT INTO %I.%I SELECT * FROM (%s) WHERE %s',
                                  rec.derived_schema, rec.derived_table, query, rec.filter);
            
            GET DIAGNOSTICS rows_affected = ROW_COUNT;
            
            -- ✅ SUCESSO: Marca como processado na temp table
            UPDATE temp_jobs_to_process 
            SET 
                status = 'Done',
                processed_at = NOW()
            WHERE id = rec.id;

            -- ✅ SUCESSO: Marca como processado na tabela real
            UPDATE syncdt._refresh_queue 
            SET processed_at = NOW()
            WHERE id = rec.id;

            total_inserted := total_inserted + rows_affected;
            
            RAISE NOTICE 'R%: Excluído e reinserido % registro(s) de %.% => %', 
                         rec.id, rows_affected, rec.derived_schema, rec.derived_table, rec.filter;

        EXCEPTION
            WHEN OTHERS THEN
                -- ❌ ERRO: Marca como erro na temp table
                UPDATE temp_jobs_to_process 
                SET 
                    status = 'Error',
                    error_message = SQLERRM
                WHERE id = rec.id;


	            UPDATE syncdt._refresh_queue 
	            SET last_try = NOW(), last_error = SQLERRM
	            WHERE id = rec.id;

                -- ❌ NÃO marca como processado na tabela real!
                -- O job permanece com processed_at = NULL para retry
                
                error_count := error_count + 1;
                
                RAISE WARNING '❌ Job %: Erro: %', rec.id, SQLERRM;
                
                -- Log do erro (mantido do código original)
                --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
                --VALUES (rec.derived_schema, rec.derived_table, 'REFRESH', start_time, NOW(), false, SQLERRM);
        END;


    END LOOP;

    -- Log de sucesso (mantido do código original, mas comentado)
    --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, rows_affected, success)
    --VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), total_inserted, true);
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log do erro (mantido do código original)
        --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        --VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), false, SQLERRM);
        
        st := ' ' || COALESCE(derived_schema || '.' || derived_table, '');
        
        RAISE WARNING 'Erro no refresh%: %', st, SQLERRM;
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
	pid int;
BEGIN
	perform syncdt._clear_queue_history();

    start_time := NOW();
	pid = pg_backend_pid();

	update syncdt._refresh_queue
	set locked_by = pid, locked_until = start_time + interval '5 minutes'
    WHERE id in 
		(SELECT id 
	     FROM syncdt._refresh_queue q
		 where processed_at is null
		   AND ((q.derived_schema = _update_changes_grouped.derived_schema AND q.derived_table = _update_changes_grouped.derived_table) OR
			   (_update_changes_grouped.derived_schema is null AND _update_changes_grouped.derived_table is null))
		   and (q.wait_until is null or q.wait_until <= NOW())  
		   and (locked_by is null or locked_by = pid or locked_until < now() or locked_until is null)		      		
	     ORDER BY triggered_at, id ASC
	     limit max_queue);

    -- FASE 1: DELETE de todos os pendentes (um por um)
    FOR rec IN
		select 	q.derived_schema, q.derived_table, 
				string_agg(filter, ' OR ') as filter, 
				array_agg(id) as ids,
				count(*) as row_count
		from (
	        SELECT * 
	        FROM syncdt._refresh_queue qq
	        WHERE locked_by = pid
	        ORDER BY triggered_at, id ASC
		) q group by q.derived_schema, q.derived_table
    LOOP
        perform syncdt.execute('DELETE FROM %I.%I WHERE %s', 
                       rec.derived_schema, rec.derived_table, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;

	    SELECT definition_query INTO query
	    FROM syncdt._derived_tables d
	    WHERE (d.table_schema = rec.derived_schema AND d.table_name = rec.derived_table);

        perform syncdt.execute('INSERT INTO %I.%I %s AND %s',
                       rec.derived_schema, rec.derived_table, query, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;

    -- Marca como processado
	    UPDATE syncdt._refresh_queue q
	    SET processed_at = NOW(), locked_at = null, locked_until = null
	    WHERE id = any(rec.ids);

    END LOOP;
    
    
    -- Log de sucesso
    --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, rows_affected, success)
    --VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), total_inserted, true);
    
    --RAISE NOTICE 'Refresh concluído para %.% (deletados: %, inseridos: %, filters: %)', $1, $2, total_deleted, total_inserted, filter_count;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log do erro
        --INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        --VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), false, SQLERRM);
        
        RAISE WARNING 'Erro no refresh de %.%: %', derived_schema, derived_table, SQLERRM;
        RAISE;
END;
$$;



CREATE OR REPLACE FUNCTION syncdt.update_changes(
	derived_table text default null,
    max_queue int default null
) RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    schema_name TEXT;
    base_table_name TEXT;
BEGIN
    -- Extrai schema e nome da tabela destino
	IF derived_table is null then
        schema_name := null;
        base_table_name := null;
    ELSIF position('.' in derived_table) > 0 THEN
        schema_name := split_part(derived_table, '.', 1);
        base_table_name := split_part(derived_table, '.', 2);
    ELSE
        schema_name := '
public';
        base_table_name := derived_table;
    END IF;
	perform syncdt._update_changes(schema_name, base_table_name, 'sequential', max_queue);
END;
$$;


CREATE OR REPLACE FUNCTION syncdt.update_changes(
	max_queue int
) RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
	perform syncdt.update_changes(null, max_queue);
END;
$$;



