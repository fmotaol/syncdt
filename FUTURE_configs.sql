-- ============================================================
-- Tabela de configurações chave-valor
-- ============================================================
CREATE TABLE IF NOT EXISTS syncdt._configs (
    id SERIAL PRIMARY KEY,
    var_name VARCHAR(100) UNIQUE NOT NULL,      -- Nome da variável (chave)
    var_value TEXT NOT NULL,                    -- Valor armazenado como texto
    var_type VARCHAR(30) DEFAULT 'text',        -- Tipo declarado para conversão
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Índice para buscas rápidas por nome
CREATE INDEX IF NOT EXISTS idx_configs_var_name ON syncdt._configs(var_name);

-- Comentários em português
COMMENT ON TABLE syncdt._configs IS 'Tabela de configurações do sistema no formato chave-valor';
COMMENT ON COLUMN syncdt._configs.var_name IS 'Nome identificador da configuração (ex: session_timeout)';
COMMENT ON COLUMN syncdt._configs.var_value IS 'Valor da configuração armazenado em texto';
COMMENT ON COLUMN syncdt._configs.var_type IS 'Tipo do valor para conversão: text, int, float, boolean, json, etc.';
COMMENT ON COLUMN syncdt._configs.updated_at IS 'Data e hora da última atualização';
COMMENT ON COLUMN syncdt._configs.created_at IS 'Data e hora da criação do registro';

-- ============================================================
-- Função para gravar/atualizar uma configuração
-- ============================================================
CREATE OR REPLACE FUNCTION syncdt._setConfig(
    varname TEXT,
    value ANYELEMENT
)
RETURNS VOID AS $$
DECLARE
    v_type TEXT;
    v_value_text TEXT;
BEGIN

	PERFORM syncdt.check_table_exists('syncdt._configs', true);

    -- Determina o tipo do valor passado
    v_type := pg_typeof(value)::TEXT;
    
    -- Converte o valor para texto
    v_value_text := value::TEXT;
    
    -- Insere ou atualiza a configuração
    INSERT INTO syncdt._configs (var_name, var_value, var_type, updated_at)
    VALUES (varname, v_value_text, v_type, NOW())
    ON CONFLICT (var_name) 
    DO UPDATE SET 
        var_value = EXCLUDED.var_value,
        var_type = EXCLUDED.var_type,
        updated_at = NOW();
    
    -- Se não inseriu nem atualizou (caso raro), faz um UPDATE explícito
    IF NOT FOUND THEN
        UPDATE syncdt._configs 
        SET var_value = v_value_text,
            var_type = v_type,
            updated_at = NOW()
        WHERE var_name = varname;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION syncdt._setConfig(TEXT, ANYELEMENT) IS 
'Grava ou atualiza uma configuração no banco. O tipo do valor é detectado automaticamente.';

-- ============================================================
-- Função para ler uma configuração com valor padrão
-- ============================================================
CREATE OR REPLACE FUNCTION syncdt._getConfig(
    varname TEXT,
    default_value ANYELEMENT DEFAULT NULL
)
RETURNS ANYELEMENT AS $$
DECLARE
    v_record RECORD;
    v_result ANYELEMENT;
    v_default_type TEXT;
    v_config_type TEXT;
BEGIN
    -- Busca a configuração
    SELECT var_value, var_type INTO v_record
    FROM syncdt._configs
    WHERE var_name = varname;
    
    -- Se não encontrou, retorna o valor padrão
    IF v_record IS NULL THEN
        RETURN default_value;
    END IF;
    
    -- Verifica se o tipo do valor padrão (se fornecido) é compatível
    IF default_value IS NOT NULL THEN
        v_default_type := pg_typeof(default_value)::TEXT;
        v_config_type := v_record.var_type;
        
        -- Se os tipos não coincidem, tenta converter
        IF v_config_type != v_default_type THEN
            -- Tenta converter para o tipo esperado
            BEGIN
                EXECUTE format('SELECT %L::%s', v_record.var_value, v_default_type) 
                INTO v_result;
                RETURN v_result;
            EXCEPTION WHEN OTHERS THEN
                -- Se falhar, retorna o valor padrão com aviso
                RAISE WARNING 'Tipo incompatível para %: config é %, esperado %. Usando valor padrão.', 
                    varname, v_config_type, v_default_type;
                RETURN default_value;
            END;
        END IF;
    END IF;
    
    -- Converte o valor para o tipo solicitado
    IF default_value IS NOT NULL THEN
        v_result := v_record.var_value::TEXT::pg_typeof(default_value);
    ELSE
        -- Se não tem default, retorna como texto
        EXECUTE format('SELECT %L::%s', v_record.var_value, v_record.var_type) 
        INTO v_result;
    END IF;
    
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION syncdt._getConfig(TEXT, ANYELEMENT) IS 
'Recupera uma configuração do banco. Se não existir, retorna o valor padrão fornecido. 
O tipo de retorno é determinado pelo default_value.';

-- ============================================================
-- Função auxiliar para listar todas as configurações (opcional)
-- ============================================================
CREATE OR REPLACE FUNCTION syncdt._listConfigs()
RETURNS TABLE(
    var_name VARCHAR(100),
    var_value TEXT,
    var_type VARCHAR(30),
    updated_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    SELECT c.var_name, c.var_value, c.var_type, c.updated_at, c.created_at
    FROM syncdt._configs c
    ORDER BY c.var_name;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION syncdt._listConfigs() IS 
'Lista todas as configurações armazenadas no banco.';

-- ============================================================
-- Função para remover uma configuração (opcional)
-- ============================================================
CREATE OR REPLACE FUNCTION syncdt._deleteConfig(
    varname TEXT
)
RETURNS BOOLEAN AS $$
DECLARE
    rows_deleted INTEGER;
BEGIN
    DELETE FROM syncdt._configs WHERE var_name = varname;
    GET DIAGNOSTICS rows_deleted = ROW_COUNT;
    RETURN rows_deleted > 0;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION syncdt._deleteConfig(TEXT) IS 
'Remove uma configuração do banco. Retorna TRUE se removeu, FALSE se não existia.';

-- ============================================================
-- Exemplos de uso (comentados)
-- ============================================================
/*
-- Gravar configurações de diferentes tipos
SELECT syncdt._setConfig('session_timeout', 3600);
SELECT syncdt._setConfig('maintenance_mode', false);
SELECT syncdt._setConfig('app_name', 'Sistema SyncDT');
SELECT syncdt._setConfig('api_timeout', 30.5);

-- Ler configurações
SELECT syncdt._getConfig('session_timeout', 300) AS timeout;
SELECT syncdt._getConfig('maintenance_mode', true) AS is_maintenance;
SELECT syncdt._getConfig('non_existent', 'default') AS fallback;

-- Listar todas
SELECT * FROM syncdt._listConfigs();

-- Remover
SELECT syncdt._deleteConfig('api_timeout');
*/