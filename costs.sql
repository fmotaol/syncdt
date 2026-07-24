
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

