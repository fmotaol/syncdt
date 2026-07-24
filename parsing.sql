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
        v_resolved_sql := syncdt.solve_expression(
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

