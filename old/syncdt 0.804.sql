create schema if not exists syncdt;



CREATE OR REPLACE FUNCTION syncdt.create_derived_table(
    table_name TEXT,
    query TEXT,
    refresh_mode TEXT DEFAULT 'auto', --auto, deferred, immediate
    primary_key TEXT DEFAULT null,
    notification_mode text default 'optimized' --optimized, full
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
    --PERFORM syncdt.test_query_syntax(query);

    -- Valida refresh_mode
    IF refresh_mode NOT IN ('auto', 'deferred', 'immediate') THEN
        RAISE EXCEPTION 'refresh_mode inválido: % (opções: auto, deferred ou immediate)', refresh_mode;
    END IF;
    
	if refresh_mode in ('deferred', 'auto') then
		squery = format('select * from (%s) limit 0', query); 
	end if;

    -- Cria a tabela com ou sem PRIMARY KEY
    --IF primary_key IS NOT NULL AND trim(primary_key) != '' THEN
		--perform syncdt.execute('CREATE TABLE %I.%I (PRIMARY KEY (%s)) AS %s', schema_name, base_table_name, primary_key, squery);
    --ELSE

        perform syncdt.execute('CREATE TABLE %I.%I AS %s', schema_name, base_table_name, squery);

    --END IF;

    IF primary_key IS NOT NULL AND trim(primary_key) != '' THEN
        perform syncdt.execute('ALTER TABLE %I.%I ADD PRIMARY KEY (%s)', schema_name, base_table_name, primary_key);
	end if;


    -- Registra metadados (sem source_tables_def)
    perform syncdt.execute('
        INSERT INTO syncdt._derived_tables (
            table_schema, table_name, definition_query, refresh_mode,
            primary_key, created_at, notification_mode
        ) VALUES (%L, %L, %L, %L, %L, NOW(), %L);
    ', schema_name, base_table_name, query, refresh_mode, primary_key, notification_mode);

    RAISE NOTICE 'Tabela derivada %.% criada com sucesso (modo: %, pk: %)',
                 schema_name, base_table_name, refresh_mode, COALESCE(primary_key, 'nenhuma');
END;
$$;





CREATE OR REPLACE FUNCTION syncdt.assign_dependency(
    derived_table TEXT,
    source_table TEXT,
    target_columns TEXT,
    source_exp TEXT,
    wait_until TEXT default null,
    use_index boolean DEFAULT true
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
    index_name TEXT;
    rec RECORD;
    pk TEXT;
    target_norm TEXT;
    pk_norm TEXT;
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

    PERFORM syncdt._test_source_exp_syntax(source_exp, source_table);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tabela derivada %.% não encontrada. Crie-a primeiro com syncdt.create_derived_table()',
                        d_schema, d_name;
    END IF;

    -- Cria trigger
    trigger_name := syncdt._create_refresh_trigger(
        d_schema, d_name, s_schema, s_name
    );


    -- Registra dependência (com index_names NULL)
    INSERT INTO syncdt._dependencies (
        derived_schema, derived_table, source_schema, source_table, 
        target_columns, source_exp, trigger_name, created_at, index_names, wait_until
    ) VALUES (
        d_schema, d_name, s_schema, s_name, 
        target_columns, source_exp, trigger_name, NOW(), NULL, wait_until
    );

    -- Cria índice se solicitado
    IF use_index THEN
        -- Busca a primary_key da tabela derivada
        SELECT primary_key INTO pk
        FROM syncdt._derived_tables
        WHERE table_schema = d_schema AND table_name = d_name;
        
        -- Normaliza target_columns
        target_norm := (
            SELECT string_agg(trim(col), ',' ORDER BY trim(col))
            FROM unnest(string_to_array(target_columns, ',')) AS col
        );
        
        -- Normaliza primary_key
        IF pk IS NOT NULL AND pk != '' THEN
            pk_norm := (
                SELECT string_agg(trim(col), ',' ORDER BY trim(col))
                FROM unnest(string_to_array(pk, ',')) AS col
            );
        ELSE
            pk_norm := '';
        END IF;
        
        -- Só cria índice se target_columns NÃO for igual à primary key
        IF target_norm != pk_norm THEN
            index_name := syncdt._create_index(
                d_schema, 
                d_name, 
                target_columns
            );
            
            -- Atualiza a dependência com o nome do índice
            UPDATE syncdt._dependencies
            SET index_names = index_name
            WHERE derived_schema = d_schema 
              AND derived_table = d_name
              AND source_schema = s_schema
              AND source_table = s_name
              AND trigger_name = trigger_name;
            
            RAISE NOTICE 'Índice % criado em %.% para colunas: %', 
                         index_name, d_schema, d_name, target_columns;
        ELSE
            RAISE NOTICE 'Nenhum índice necessário - target_columns já são a primary key de %.%', 
                         d_schema, d_name;
        END IF;
    END IF;

    RAISE NOTICE 'Source table %.% atribuída a %.% (trigger: %)',
                 s_schema, s_name, d_schema, d_name, trigger_name;
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
    perform syncdt.execute('DROP TABLE IF EXISTS %I.%I CASCADE', schema_name, base_table_name);

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

    --RAISE debug 'source_exp syntax OK: %', source_exp;
    
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





CREATE OR REPLACE FUNCTION syncdt._create_index(
    table_schema text,
    table_name text,
    columns text,
    condition text DEFAULT NULL
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    index_name text;
    full_table_name text;
    create_index_sql text;
BEGIN
    -- Gera nome do índice baseado na tabela e colunas
    index_name := left(
        format('idx_%s_%s_%s', 
            table_name, 
            replace(replace(columns, ' ', ''), ',', '_'), 
            'ref'
        ), 
        63
    );
    
    -- Nome completo da tabela
    full_table_name := format('%I.%I', table_schema, table_name);
    
    -- Monta o SQL para criar o índice
    create_index_sql := format(
        'CREATE INDEX IF NOT EXISTS %I ON %s (%s)',
        index_name,
        full_table_name,
        columns
    );
    
    -- Adiciona condição WHERE se fornecida
    IF condition IS NOT NULL THEN
        create_index_sql := create_index_sql || format(' WHERE %s', condition);
    END IF;
    
    -- Executa a criação do índice
    EXECUTE create_index_sql;
    
    RETURN index_name;
END;
$$;



CREATE OR REPLACE FUNCTION syncdt._create_refresh_trigger(
    derived_schema TEXT, derived_table TEXT,
    source_schema TEXT, source_name TEXT
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    trigger_name TEXT;
	rec record;
BEGIN
    -- Gera nome único para a trigger
    trigger_name := left(format('z_syncdt_%s_%s_%s', derived_table, source_schema, source_name), 63);

	select refresh_mode, notification_mode into rec
		from syncdt._derived_tables d
		where d.table_schema = $1 and d.table_name = $2;
    
    perform syncdt.execute('
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE OR DELETE ON %I.%I
        FOR EACH ROW
        EXECUTE FUNCTION syncdt._trigger_on_source_changed(%L, %L, %L, %L);',
        trigger_name, source_schema, source_name,
        derived_schema, derived_table,
		source_schema, source_name
    );

	return trigger_name;
END;
$$;




CREATE OR REPLACE FUNCTION syncdt._trigger_on_source_changed()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
	expold text = null;
	expnew text = null;
	expw_old TEXT = null;
	expw_new TEXT = null;
	rec record;
BEGIN
	select t.table_schema as derived_schema, t.table_name as derived_table, d.source_schema, d.source_table,
			refresh_mode, notification_mode, target_columns, source_exp, wait_until into rec
		from syncdt._derived_tables t
		join syncdt._dependencies d on t.table_schema = d.derived_schema and t.table_name = d.derived_table
		where t.table_schema = TG_ARGV[0] and t.table_name = TG_ARGV[1]
		  and d.source_schema = TG_ARGV[2] and d.source_table = TG_ARGV[3]; 

	if not FOUND then
		raise exception 'Erro interno: propriedades não encontradas';
	end if;

	if TG_OP = 'DELETE' or TG_OP = 'UPDATE' then
		expold = syncdt._solve_record_expression(rec.source_exp, OLD);
	end if;

	if TG_OP = 'INSERT' or TG_OP = 'UPDATE' then
		expnew = syncdt._solve_record_expression(rec.source_exp, NEW);
	end if;

	IF TG_OP = 'UPDATE' and expold = expnew then
		return NULL;
	END IF;

	if rec.wait_until is not null then
	    --insert into syncdt._temp_log(message) values ( 
	        --format('wait_until: %s | Record: %s', rec.wait_until, rec)
		--);

		if expold is not null then
			expw_old = syncdt._solve_record_expression(rec.wait_until, OLD, true);
		end if;

		if expnew is not null then
			expw_new = syncdt._solve_record_expression(rec.wait_until, NEW, true);
		end if;
	end if;

    IF TG_OP = 'DELETE' THEN
	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expold, expw_old::timestamptz);
    ELSIF TG_OP = 'INSERT' THEN
	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expnew, expw_new::timestamptz);
    ELSIF TG_OP = 'UPDATE' THEN
	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expold, expw_old::timestamptz);
	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expnew, expw_new::timestamptz);
    END IF;
    
    RETURN NULL;
END;
$$;




CREATE OR REPLACE FUNCTION syncdt.notify_source_changed(derived_table text, source_table text, source_record record)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
	exp text = null;
	rec record;
BEGIN
	select t.table_schema as derived_schema, t.table_name as derived_table, d.source_schema, d.source_table,
			refresh_mode, notification_mode, target_columns, source_exp, wait_until into rec
		from syncdt._derived_tables t
		join syncdt._dependencies d on t.table_schema = d.derived_schema and t.table_name = d.derived_table
		where (t.table_schema || '.' || t.table_name = $1 OR t.table_schema = 'public' AND t.table_name = $1)
		  and (d.source_schema || '.' || d.source_table = $2 OR d.source_schema = 'public' AND d.source_table = $2); 

	if not FOUND then
		raise exception 'Não foi identificada dependência entre as tabelas % e %', $1, $2;
	end if;

	exp = syncdt._solve_record_expression(rec.source_exp, source_record);

    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, 
    	rec.source_schema, rec.source_table, exp, null);
END;
$$;




CREATE OR REPLACE DROP FUNCTION syncdt._notify_source_changed(
    derived_schema TEXT,
    derived_table TEXT,
    refresh_mode text,
    notification_mode text,
    target_columns text, 
    source_schema text, 
    source_table text,
    source_exp text,
    wait_until timestamptz
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    drec RECORD;
    sfilter TEXT;
    c FLOAT;
BEGIN
    -- Constrói o filter usando o column_mapping
    sfilter := syncdt._build_filter(target_columns, source_exp);
    
    -- Enfileira o refresh
	if notification_mode = 'optimized' then

		INSERT INTO syncdt._refresh_queue (derived_schema, derived_table, triggered_at, filter, wait_until, source_schema, source_table)
			SELECT $1, $2, NOW(), sfilter, $9, $6, $7
		WHERE NOT EXISTS (SELECT * FROM syncdt._refresh_queue q
		    WHERE q.derived_schema = $1 AND q.derived_table = $2
		      AND (q.wait_until IS NULL OR q.wait_until < $9)
			  AND q.filter = sfilter AND q.processed_at IS NULL);

	elsif notification_mode = 'full' then

		raise exception 'notification_mode full temporariamente supensa';

	    INSERT INTO syncdt._refresh_queue (derived_schema, derived_table, triggered_at, filter, wait_until, source_schema, source_table)
	    VALUES ($1, $2, NOW(), sfilter, $9, $6, $7);

	else
		raise exception 'Modo de notificação desconhecido: %', notification_mode;
	end if;

    IF refresh_mode = 'immediate' THEN
        PERFORM syncdt._update_changes(derived_schema, derived_table);

    ELSIF refresh_mode = 'auto' THEN
        c := syncdt.pending_refresh_cost(derived_schema, derived_table);
        
        IF c > 0.7 * syncdt.total_cost(derived_schema, derived_table) THEN	 
            PERFORM syncdt._update_changes(derived_schema, derived_table);
        END IF;
    ELSIF refresh_mode = 'deferred' THEN
		--Não precisa fazer nada. As notificações vão automaticamente preencher a tabela de notificações.
    END IF;
END;
$$;



CREATE OR REPLACE FUNCTION syncdt._solve_record_expression(
    sql_exp text, 
    rec record, 
    execute boolean DEFAULT false,
    placeholder text DEFAULT '\$\{source\.([a-zA-Z_][a-zA-Z0-9_]*)\}'
)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    v_result text;
    v_column_name text;
    v_column_value text;
    v_formatted_value text;
    v_sql text;
    v_match text[];
    v_execute_result text;
    v_error_message text;
BEGIN
    v_result := sql_exp;
    
    -- Usa regexp_matches para encontrar TODOS os placeholders
    FOR v_match IN 
        SELECT regexp_matches(v_result, '\$\{source\.([a-zA-Z_][a-zA-Z0-9_]*)\}', 'g')
    LOOP
        v_column_name := v_match[1];
        
        v_sql := format('SELECT ($1).%I::text', v_column_name);
        EXECUTE v_sql INTO v_column_value USING rec;
        
        v_formatted_value := syncdt.format_sql_value(v_column_value);
        v_result := replace(v_result, '${source.' || v_column_name || '}', v_formatted_value);
            
    END LOOP;
    
    -- Se execute for true, executa a SQL resultante
    IF execute THEN
        --RAISE NOTICE 'Executando SQL: %', v_result;
        
        -- Executa a SQL e captura o resultado como texto
        EXECUTE format('SELECT (%s)::text', v_result) INTO v_execute_result;
        
        -- Se o resultado for NULL, converte para string vazia
        IF v_execute_result IS NULL THEN
            v_execute_result := '';
        END IF;
        
        --RAISE NOTICE 'Resultado da execução: %', v_execute_result;
        
        RETURN v_execute_result;
        
    END IF;
    
    -- Se execute for false, retorna apenas a SQL construída
    RETURN v_result;
END;
$function$;


-- DROP FUNCTION syncdt.format_sql_value(text);

CREATE OR REPLACE FUNCTION syncdt.format_sql_value(raw text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
BEGIN
    IF raw IS NULL OR raw = 'NULL' THEN
        return 'NULL';
    ELSIF raw ~ '^-?\d+(\.\d+)?$' THEN
        return raw;
    ELSIF raw IN ('t', 'f', 'true', 'false') THEN
        return raw;
    ELSE
        return quote_literal(raw);
    END IF;
END;
$function$
;




CREATE OR REPLACE FUNCTION syncdt.solve_expression(
    sql_exp text, 
    rec record, 
    record_ph text DEFAULT '\$\{source\.([a-zA-Z_][a-zA-Z0-9_]*)\}',
    query_ph text DEFAULT '\$\{select'
)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    v_result text;
    v_pos integer;
    v_start_pos integer;
    v_end_pos integer;
    v_depth integer;
    v_placeholder text;
    v_inner_sql text;
    v_resolved_sql text;
    v_query_result text;
    v_column_name text;
    v_column_value text;
    v_formatted_value text;
    v_sql text;
    v_match text[];
    v_temp_result text;
    v_is_literal boolean;
    v_placeholder_type text;
BEGIN
    v_result := sql_exp;
    
    -- Validação inicial: verifica se o placeholder de registro contém "select"
    IF record_ph ~* 'select' THEN
        RAISE EXCEPTION 'O placeholder de registro não pode conter "select" para evitar ambiguidade.';
    END IF;
    
    -- Se o registro é nulo, verifica se há referência a placeholders de registro
    IF rec IS NULL THEN
        -- Verifica se existe algum placeholder de registro na expressão
        IF v_result ~ record_ph THEN
            RAISE EXCEPTION 'Registro é nulo mas a expressão contém referência a placeholder de registro: %', v_result;
        END IF;
    END IF;
    
    -- Primeiro passo: resolver placeholders de registro (mais internos)
    FOR v_match IN 
        SELECT regexp_matches(v_result, record_ph, 'g')
    LOOP
        v_column_name := v_match[1];
        v_placeholder := '${source.' || v_column_name || '}';
        
        -- Obtém o valor da coluna do registro
        v_sql := format('SELECT ($1).%I::text', v_column_name);
        EXECUTE v_sql INTO v_column_value USING rec;
        
        -- Verifica se é placeholder literal (termina com ::.)
        IF v_result LIKE '%${source.' || v_column_name || '}::.%' THEN
            -- Placeholder literal: substitui sem formatação
            v_formatted_value := v_column_value;
            v_placeholder := '${source.' || v_column_name || '}::.';
        ELSE
            -- Placeholder normal: formata o valor
            v_formatted_value := syncdt.format_sql_value(v_column_value);
        END IF;
        
        v_result := replace(v_result, v_placeholder, v_formatted_value);
    END LOOP;
    
    -- Segundo passo: resolver placeholders de query (recursivamente com parser de chaves)
    v_pos := 1;
    v_temp_result := v_result;
    v_result := '';
    
    WHILE v_pos <= length(v_temp_result) LOOP
        -- Procura por '${select' no texto
        v_start_pos := position('${select' in substring(v_temp_result, v_pos));
        
        IF v_start_pos = 0 THEN
            -- Não encontrou mais placeholders, adiciona o resto do texto
            v_result := v_result || substring(v_temp_result, v_pos);
            EXIT;
        END IF;
        
        -- Adiciona o texto antes do placeholder
        v_result := v_result || substring(v_temp_result, v_pos, v_start_pos - 1);
        
        -- Posição do início do placeholder
        v_pos := v_pos + v_start_pos - 1;
        
        -- Encontra a chave de abertura do placeholder
        v_start_pos := position('${select' in substring(v_temp_result, v_pos));
        IF v_start_pos = 0 THEN
            EXIT;
        END IF;
        
        v_pos := v_pos + v_start_pos - 1;
        
        -- Pula o '${select'
        v_pos := v_pos + 8; -- length of '${select'
        
        -- Verifica se é placeholder literal (termina com ::.)
        v_is_literal := FALSE;
        v_placeholder_type := 'normal';
        
        -- Agora encontra o '}' correspondente com contagem de profundidade
        v_depth := 1;
        v_end_pos := v_pos;
        
        WHILE v_depth > 0 AND v_end_pos <= length(v_temp_result) LOOP
            v_end_pos := v_end_pos + 1;
            IF substring(v_temp_result, v_end_pos, 1) = '{' THEN
                v_depth := v_depth + 1;
            ELSIF substring(v_temp_result, v_end_pos, 1) = '}' THEN
                v_depth := v_depth - 1;
                
                -- Verifica se o fechamento é seguido por ::.
                IF v_depth = 0 AND v_end_pos + 3 <= length(v_temp_result) THEN
                    IF substring(v_temp_result, v_end_pos + 1, 3) = '::.' THEN
                        v_is_literal := TRUE;
                        v_placeholder_type := 'literal';
                    END IF;
                END IF;
            END IF;
        END LOOP;
        
        IF v_depth > 0 THEN
            RAISE EXCEPTION 'Placeholder não fechado encontrado em: %', 
                substring(v_temp_result, v_pos - 8, v_end_pos - v_pos + 9);
        END IF;
        
        -- Extrai o conteúdo interno (sem as chaves externas)
        v_inner_sql := substring(v_temp_result, v_pos, v_end_pos - v_pos);
        
        -- Monta o placeholder completo para substituição
        IF v_is_literal THEN
            v_placeholder := '${select' || v_inner_sql || '}::.';
        ELSE
            v_placeholder := '${select' || v_inner_sql || '}';
        END IF;
        
        -- Chamada recursiva para resolver os placeholders dentro do SQL interno
        v_resolved_sql := syncdt.solve_expression(
            v_inner_sql, 
            rec, 
            record_ph, 
            '${select'
        );
        
        -- Executa o SQL resolvido
        BEGIN
            EXECUTE format('select (select %s)::text', v_resolved_sql) INTO v_query_result;
            
            -- Se o resultado for NULL, converte para string vazia
            IF v_query_result IS NULL THEN
                v_query_result := '';
            END IF;
            
            -- CORREÇÃO AQUI: Formata ou não dependendo do tipo
            IF v_is_literal THEN
                -- Placeholder literal: insere o valor diretamente SEM formatação
                v_result := v_result || v_query_result;
            ELSE
                -- Placeholder normal: formata o valor com aspas
                v_result := v_result || syncdt.format_sql_value(v_query_result);
            END IF;
            
        EXCEPTION WHEN OTHERS THEN
            RAISE EXCEPTION 'Erro ao executar SQL interno "%": %', v_resolved_sql, SQLERRM;
        END;
        
        -- Move para depois do placeholder processado
        IF v_is_literal THEN
            v_pos := v_end_pos + 4; -- +4 para pular o '::.'
        ELSE
            v_pos := v_end_pos + 1;
        END IF;
    END LOOP;
    
    RETURN v_result;
END;
$function$;






-- Placeholder de registro normal (com formatação)
SELECT syncdt.solve_expression(
    'INS-ERT INTO logs (usuario, data) VALUES (${source.nome}, now())',
    p
) from tlm.ponto p

SELECT syncdt.solve_expression(
    'SELECT * FROM tabela WHERE id = ${source.nome}::.',
    p
) from tlm.ponto p
-- Resultado: SELECT * FROM tabela WHERE id = 123

-- Placeholder de query normal (com formatação)
SELECT syncdt.solve_expression(
    $$SELECT * FROM logs 
	WHERE usuario = ${select nome from tlm.ponto 
		where id = ${source.id}}::. 
	  and usuario_anterior = ${select nome_antigo from tlm.ponto 
		where id = ${source.id}}
	$$,
    p
) from tlm.ponto p

-- Placeholder de query literal (sem formatação)
SELECT syncdt.solve_expression(
    'SELECT * FROM logs WHERE id IN (${select string_agg(id::text, '','') from pedidos where cliente_id = ${source.id}}::.)',
    row(5)::meu_tipo
);
-- Resultado: SELECT * FROM logs WHERE id IN (1,2,3,4,5)









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
    filter := format('(%s) %s', target_columns, source_exp);    
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
END;
$$;




CREATE OR REPLACE FUNCTION syncdt.execute(
    sql text,
    VARIADIC params text[]
)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    formatted_sql text;
BEGIN
    -- Formata o SQL com os parâmetros fornecidos
    formatted_sql := format(sql, VARIADIC params);
    
    -- Executa o SQL formatado
    EXECUTE formatted_sql;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Exibe o SQL que causou erro via RAISE NOTICE
        RAISE NOTICE 'Erro no SQL: %', formatted_sql;
        
        -- Relança a exceção para cima
        RAISE;
END;
$$;


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
		where d.table_schema = $1 and table_name = $2;

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
	st text;
BEGIN
    start_time := NOW();
	pid = pg_backend_pid();

	update syncdt._refresh_queue
	set locked_by = pid, locked_until = start_time + interval '5 minutes'
    WHERE id in 
		(SELECT id 
	     FROM syncdt._refresh_queue q
		 where processed_at is null
		   AND ((q.derived_schema = $1 AND q.derived_table = $2) OR
			   ($1 is null AND $2 is null))
		   and (q.wait_until is null or q.wait_until <= NOW())  
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
	    raise notice 'Excluindo %.% where %', rec.derived_schema, rec.derived_table, rec.FILTER;
    
        perform syncdt.execute('DELETE FROM %I.%I WHERE %s',
                       rec.derived_schema, rec.derived_table, rec.filter);
        
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
	    WHERE (d.table_schema = rec.derived_schema AND d.table_name = rec.derived_table);

		if not FOUND or query is null then
			raise exception 'definition_query não encontrada';
		end if;

	    raise notice 'Reinserindo %.% where %', rec.derived_schema, rec.derived_table, rec.FILTER;
		
        perform syncdt.execute('INSERT INTO %I.%I select * from (%s) where %s',
                       rec.derived_schema, rec.derived_table, query, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_inserted := total_inserted + rows_affected;

    -- Marca como processado
	    UPDATE syncdt._refresh_queue 
	    SET processed_at = NOW(), locked_by = null, locked_until = null
	    WHERE id = rec.id;
    END LOOP;

    
    -- Log de sucesso
    INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, rows_affected, success)
    VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), total_inserted, true);
    
    --RAISE NOTICE 'Refresh concluído (deletados: %, inseridos: %, filters: %)', total_deleted, total_inserted, filter_count;
    
EXCEPTION
    WHEN OTHERS THEN
        -- Log do erro
        INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, success, error_message)
        VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), false, SQLERRM);
        
		st = ' ' || derived_schema || '.' || derived_table;
		if st is null then
			st = '';
		end if;

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
    filter_count INTEGER := 0;
	pid int;
BEGIN
    start_time := NOW();
	pid = pg_backend_pid();

	update syncdt._refresh_queue
	set locked_by = pid, locked_until = start_time + interval '5 minutes'
    WHERE id in 
		(SELECT id 
	     FROM syncdt._refresh_queue q
		 where processed_at is null
		   AND ((q.derived_schema = $1 AND q.derived_table = $2) OR
			   ($1 is null AND $2 is null))
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
		filter_count = rec.row_count;

        perform syncdt.execute('DELETE FROM %I.%I WHERE %s', 
                       rec.derived_schema, rec.derived_table, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;

	    SELECT definition_query INTO query
	    FROM syncdt._derived_tables d
	    WHERE (d.table_schema = rec.derived_schema AND d.table_name = rec.derived_table);

        perform syncdt.execute('INSERT INTO %I.%I %s AND %s ON CONFLICT DO NOTHING',
                       rec.derived_schema, rec.derived_table, query, rec.filter);
        GET DIAGNOSTICS rows_affected = ROW_COUNT;
        total_deleted := total_deleted + rows_affected;

    -- Marca como processado
	    UPDATE syncdt._refresh_queue q
	    SET processed_at = NOW(), locked_at = null, locked_until = null
	    WHERE id = any(rec.ids);

    END LOOP;
    
    
    -- Log de sucesso
    INSERT INTO syncdt._logs (table_schema, table_name, command, started_at, completed_at, rows_affected, success)
    VALUES (derived_schema, derived_table, 'REFRESH', start_time, NOW(), total_inserted, true);
    
    --RAISE NOTICE 'Refresh concluído para %.% (deletados: %, inseridos: %, filters: %)', $1, $2, total_deleted, total_inserted, filter_count;
    
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
		index_names text
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
        processed_at TIMESTAMPTZ,
		wait_until TIMESTAMPTZ,
		source_schema text,
		source_table text
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
	primary_key => 'dia, tag_id'
);


select syncdt.assign_dependency(
		derived_table => 'tlm.resumo_leituras_tag_dia',
		source_table => 'tlm.leitura_tag',
		target_columns => 'dia, tag_id',
		source_exp => '= (dref(${source.diahora}), ${source.tag})',
		wait_until => $$${select dref(${source.diahora}) + interval '1 day'}$$
);


select syncdt.assign_dependency(
		derived_table => 'tlm.resumo_leituras_tag_dia',
		source_table => 'tlm.revisao_ponto',
		target_columns => 'tag_id',
		source_exp =>  $$in (${select string_agg(id::text, ', ') 
                               from tlm.tag where ponto = ${source.ponto}})$$
);






--DROP TRIGGER IF EXISTS syncdt_resumo_leituras_tag_dia_tlm_leitura_tag ON tlm.leitura_tag;

--select syncdt.drop_derived_table('tlm.resumo_leituras_tag_dia')

--select syncdt._create_refresh_trigger('tlm', 'resumo_leituras_tag_dia', 'tlm', 'leitura_tag') 

--select syncdt.refresh_derived_table('tlm.resumo_leituras_tag_dia')





