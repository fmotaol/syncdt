

CREATE OR REPLACE FUNCTION syncdt.check_table_exists(
    table_full_name TEXT, raise_error boolean default true
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    sn TEXT;
    tn TEXT;
    table_exists BOOLEAN;
BEGIN
    IF position('.' in table_full_name) > 0 THEN
        sn := split_part(table_full_name, '.', 1);
        tn := split_part(table_full_name, '.', 2);
    ELSE
        sn := 'public';
        tn := table_full_name;
    END IF;
    
    SELECT EXISTS (
        SELECT 1 
        FROM information_schema.tables 
        WHERE table_schema = sn 
          AND table_name = tn
    ) INTO table_exists;
    
    IF NOT table_exists THEN
		if raise_error then
        	RAISE EXCEPTION 'Tabela não existe: %.%', sn, tn;
		else
			return false;
		end if;
    END IF;
    
    RETURN table_exists;
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




