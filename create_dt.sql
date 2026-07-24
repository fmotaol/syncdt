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
    PERFORM syncdt.test_query_syntax(query);

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
    source_columns TEXT default '*',
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

    --PERFORM syncdt._test_source_exp_syntax(source_exp, source_table);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tabela derivada %.% não encontrada. Crie-a primeiro com syncdt.create_derived_table()',
                        d_schema, d_name;
    END IF;

    -- Cria trigger
    trigger_name := syncdt._create_refresh_trigger(
        d_schema, d_name, s_schema, s_name, assign_dependency.source_columns
    );

    -- Registra dependência (com index_names NULL)
    INSERT INTO syncdt._dependencies (
        derived_schema, derived_table, source_schema, source_table, target_columns, 
		source_exp, trigger_name, created_at, index_names, wait_until, source_columns
    ) VALUES (
        d_schema, d_name, s_schema, s_name, 
        target_columns, source_exp, trigger_name, NOW(), NULL, wait_until, assign_dependency.source_columns
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
            UPDATE syncdt._dependencies d
            SET index_names = index_name
            WHERE d.derived_schema = d_schema 
              AND d.derived_table = d_name
              AND d.source_schema = s_schema
              AND d.source_table = s_name;
              --AND trigger_name = trigger_name;
            
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
