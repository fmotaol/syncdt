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

--select * from search('solve_expression')

--drop FUNCTION syncdt.solve_expression

--Função antiga, será desativada.
CREATE OR REPLACE FUNCTION syncdt._solve_expression(
    sql_exp text, 
    rec record default null, 
    record_ph text DEFAULT '\$\{source\.([a-zA-Z_][a-zA-Z0-9_]*)\}|\$source\.([a-zA-Z_][a-zA-Z0-9_]*)',
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
    v_column_name2 text;  -- Para o segundo grupo de captura
    v_column_value text;
    v_formatted_value text;
    v_sql text;
    v_match text[];
    v_temp_result text;
    v_is_literal boolean;
    v_placeholder_type text;
    v_original_placeholder text;  -- Guarda o placeholder original encontrado
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
        -- Determina qual formato foi usado
        IF v_match[1] IS NOT NULL THEN
            -- Formato com chaves: ${source.campo}
            v_column_name := v_match[1];
            v_original_placeholder := '${source.' || v_column_name || '}';
        ELSIF v_match[2] IS NOT NULL THEN
            -- Formato sem chaves: $source.campo
            v_column_name := v_match[2];
            v_original_placeholder := '$source.' || v_column_name;
        ELSE
            RAISE EXCEPTION 'Formato de placeholder inválido: %', v_match;
        END IF;
        
        -- Obtém o valor da coluna do registro
        v_sql := format('SELECT ($1).%I::text', v_column_name);
        EXECUTE v_sql INTO v_column_value USING rec;
        
        -- Verifica se é placeholder literal (termina com ::.)
        IF v_result LIKE '%' || v_original_placeholder || '::.%' THEN
            -- Placeholder literal: substitui sem formatação
            v_formatted_value := v_column_value;
            v_original_placeholder := v_original_placeholder || '::.';
        ELSE
            -- Placeholder normal: formata o valor
            v_formatted_value := syncdt.format_sql_value(v_column_value);
        END IF;
        
        -- Substitui o placeholder pelo valor formatado
        v_result := replace(v_result, v_original_placeholder, v_formatted_value);
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
        v_pos := v_pos + 2; -- length of '${'
        
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
        v_resolved_sql := syncdt._solve_expression(
            v_inner_sql, 
            rec, 
            record_ph, 
            '${select'
        );
        
        -- Executa o SQL resolvido
        BEGIN
            EXECUTE format('select (%s)::text', v_resolved_sql) INTO v_query_result;
            
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



--@TODO FUNÇÃO NOVA, AINDA NÃO TESTADA
CREATE OR REPLACE FUNCTION syncdt.solve_expression(
    sql_exp text, 
    rec record default null,
    rec_name text default null,
    ph_char text default '$',
    ph_brackets text default '{}',
    sql_native_conversion text default '::.',
    process_subqueries boolean default true
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
    v_original_placeholder text;
    v_open_bracket char;
    v_close_bracket char;
    v_placeholder_pattern text;
    v_ph_escaped text;
    v_query_pattern text;
    v_record_name text;
    v_conversion_len integer;
BEGIN
    -- Se sql_exp for nulo, retorna nulo
    IF sql_exp IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- Validação: ph_brackets deve ser um par válido
    IF ph_brackets NOT IN ('{}', '[]', '()', '<>') THEN
        RAISE EXCEPTION 'ph_brackets deve ser um dos pares: {}, [], (), <>. Recebido: %', ph_brackets;
    END IF;
    
    -- Validação: sql_native_conversion não pode ser vazio
    IF sql_native_conversion IS NULL OR sql_native_conversion = '' THEN
        RAISE EXCEPTION 'sql_native_conversion não pode ser vazio';
    END IF;
    
    v_open_bracket := substring(ph_brackets, 1, 1);
    v_close_bracket := substring(ph_brackets, 2, 2);
    v_conversion_len := char_length(sql_native_conversion);
    
    -- Define o nome padrão do registro se não foi informado
    IF rec_name IS NULL THEN
        v_record_name := 'source';
    ELSE
        -- Valida o nome do registro
        IF rec_name !~ '^[a-zA-Z_][a-zA-Z0-9_]*$' THEN
            RAISE EXCEPTION 'Nome de registro inválido: %', rec_name;
        END IF;
        v_record_name := rec_name;
    END IF;
    
    -- Inicializa o resultado
    v_result := sql_exp;
    
    -- Processa o registro se não for nulo
    IF rec IS NOT NULL THEN
        -- Escapa o caractere especial para regex se necessário
        v_ph_escaped := regexp_replace(ph_char, '([$])', '\\\1', 'g');
        
        -- Constrói o padrão para este registro
        v_placeholder_pattern := format(
            '%s%s%s%s\.([a-zA-Z_][a-zA-Z0-9_]*)%s|%s%s\.([a-zA-Z_][a-zA-Z0-9_]*)',
            v_ph_escaped,
            v_open_bracket,
            v_record_name,
            '.',
            v_close_bracket,
            v_ph_escaped,
            v_record_name,
            '.'
        );
        
        -- Verifica se existe placeholder para este registro
        IF v_result ~ v_placeholder_pattern THEN
            -- Processa os placeholders deste registro
            FOR v_match IN 
                SELECT regexp_matches(v_result, v_placeholder_pattern, 'g')
            LOOP
                -- Determina qual formato foi usado
                IF v_match[1] IS NOT NULL THEN
                    -- Formato com brackets: ${source.campo} ou [source.campo] etc.
                    v_column_name := v_match[1];
                    v_original_placeholder := format('%s%s%s%s.%s%s', 
                        ph_char, v_open_bracket, v_record_name, '.', v_column_name, v_close_bracket);
                ELSIF v_match[2] IS NOT NULL THEN
                    -- Formato sem brackets: $source.campo
                    v_column_name := v_match[2];
                    v_original_placeholder := format('%s%s.%s', ph_char, v_record_name, v_column_name);
                ELSE
                    RAISE EXCEPTION 'Formato de placeholder inválido para registro %: %', v_record_name, v_match;
                END IF;
                
                -- Obtém o valor da coluna do registro
                v_sql := format('SELECT ($1).%I::text', v_column_name);
                EXECUTE v_sql INTO v_column_value USING rec;
                
                -- Verifica se é placeholder literal (termina com sql_native_conversion)
                IF v_result LIKE '%' || v_original_placeholder || sql_native_conversion || '%' THEN
                    -- Placeholder literal: substitui sem formatação
                    v_formatted_value := v_column_value;
                    v_original_placeholder := v_original_placeholder || sql_native_conversion;
                ELSE
                    -- Placeholder normal: formata o valor
                    v_formatted_value := syncdt.format_sql_value(v_column_value);
                END IF;
                
                -- Substitui o placeholder pelo valor formatado
                v_result := replace(v_result, v_original_placeholder, v_formatted_value);
            END LOOP;
        END IF;
    END IF;
    
    -- Segundo passo: resolver placeholders de query (se habilitado)
    IF process_subqueries THEN
        -- Constrói o padrão para queries
        v_query_pattern := format('%s%sselect', ph_char, v_open_bracket);
        v_pos := 1;
        v_temp_result := v_result;
        v_result := '';
        
        WHILE v_pos <= length(v_temp_result) LOOP
            -- Procura por placeholders de query no texto
            v_start_pos := position(v_query_pattern in substring(v_temp_result, v_pos));
            
            IF v_start_pos = 0 THEN
                -- Não encontrou mais placeholders, adiciona o resto do texto
                v_result := v_result || substring(v_temp_result, v_pos);
                EXIT;
            END IF;
            
            -- Adiciona o texto antes do placeholder
            v_result := v_result || substring(v_temp_result, v_pos, v_start_pos - 1);
            
            -- Posição do início do placeholder
            v_pos := v_pos + v_start_pos - 1;
            
            -- Encontra a abertura do placeholder
            v_start_pos := position(v_query_pattern in substring(v_temp_result, v_pos));
            IF v_start_pos = 0 THEN
                EXIT;
            END IF;
            
            v_pos := v_pos + v_start_pos - 1;
            
            -- Pula o prefixo
            v_pos := v_pos + char_length(ph_char) + 1; -- +1 para o bracket de abertura
            
            -- Verifica se é placeholder literal (termina com sql_native_conversion)
            v_is_literal := FALSE;
            
            -- Encontra o bracket de fechamento correspondente com contagem de profundidade
            v_depth := 1;
            v_end_pos := v_pos;
            
            WHILE v_depth > 0 AND v_end_pos <= length(v_temp_result) LOOP
                v_end_pos := v_end_pos + 1;
                IF substring(v_temp_result, v_end_pos, 1) = v_open_bracket THEN
                    v_depth := v_depth + 1;
                ELSIF substring(v_temp_result, v_end_pos, 1) = v_close_bracket THEN
                    v_depth := v_depth - 1;
                    
                    -- Verifica se o fechamento é seguido por sql_native_conversion
                    IF v_depth = 0 AND v_end_pos + v_conversion_len <= length(v_temp_result) THEN
                        IF substring(v_temp_result, v_end_pos + 1, v_conversion_len) = sql_native_conversion THEN
                            v_is_literal := TRUE;
                        END IF;
                    END IF;
                END IF;
            END LOOP;
            
            IF v_depth > 0 THEN
                RAISE EXCEPTION 'Placeholder não fechado encontrado em: %', 
                    substring(v_temp_result, v_pos - char_length(v_query_pattern), v_end_pos - v_pos + char_length(v_query_pattern) + 1);
            END IF;
            
            -- Extrai o conteúdo interno (sem as chaves externas)
            v_inner_sql := substring(v_temp_result, v_pos, v_end_pos - v_pos);
            
            -- Monta o placeholder completo para substituição
            IF v_is_literal THEN
                v_placeholder := format('%s%sselect%s%s%s%s', ph_char, v_open_bracket, v_inner_sql, v_close_bracket, sql_native_conversion);
            ELSE
                v_placeholder := format('%s%sselect%s%s%s', ph_char, v_open_bracket, v_inner_sql, v_close_bracket);
            END IF;
            
            -- Chamada recursiva para resolver os placeholders dentro do SQL interno
            v_resolved_sql := syncdt.solve_expression(
                v_inner_sql, 
                rec, 
                v_record_name, 
                ph_char, 
                ph_brackets,
                sql_native_conversion,
                process_subqueries
            );
            
            -- Executa o SQL resolvido
            BEGIN
                EXECUTE format('select (%s)::text', v_resolved_sql) INTO v_query_result;
                
                -- Se o resultado for NULL, converte para string vazia
                IF v_query_result IS NULL THEN
                    v_query_result := '';
                END IF;
                
                -- Formata ou não dependendo do tipo
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
                v_pos := v_end_pos + v_conversion_len; -- Pula o sql_native_conversion
            ELSE
                v_pos := v_end_pos + 1;
            END IF;
        END LOOP;
    END IF;
    
    RETURN v_result;
END;
$function$;






--@TODO FUNÇÃO NOVA, AINDA NÃO TESTADA
CREATE OR REPLACE FUNCTION syncdt.solve_expression(
    sql_exp text, 
    rec1 record,
    rec_name1 text,
    rec2 record,
    rec_name2 text,
    ph_char text default '$',
    ph_brackets text default '{}',
    sql_native_conversion text default '::.',
    process_subqueries boolean default true
)
RETURNS text
LANGUAGE plpgsql
AS $function$
DECLARE
    v_result text;
BEGIN
    -- Se sql_exp for nulo, retorna nulo
    IF sql_exp IS NULL THEN
        RETURN NULL;
    END IF;
    
    -- Primeiro: processa o rec1
    v_result := syncdt.solve_expression(
        sql_exp,
        rec1,
        rec_name1,
        ph_char,
        ph_brackets,
        sql_native_conversion,
        process_subqueries
    );
    
    -- Segundo: processa o rec2 sobre o resultado do primeiro
    v_result := syncdt.solve_expression(
        v_result,
        rec2,
        rec_name2,
        ph_char,
        ph_brackets,
        sql_native_conversion,
        process_subqueries
    );
    
    RETURN v_result;
END;
$function$;