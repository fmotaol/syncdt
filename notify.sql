CREATE OR REPLACE FUNCTION syncdt._create_refresh_trigger(
    derived_schema TEXT, derived_table TEXT,
    source_schema TEXT, source_name TEXT,
    source_columns TEXT default '*'
)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    trigger_name TEXT;
	rec record;
	update_columns TEXT = '';
BEGIN
    -- Gera nome único para a trigger
    trigger_name := left(format('z_syncdt_%s_%s_%s', derived_table, source_schema, source_name), 63);

	select refresh_mode, notification_mode into rec
		from syncdt._derived_tables d
		where d.table_schema = _create_refresh_trigger.derived_schema and d.table_name = _create_refresh_trigger.derived_table;
    
	if source_columns <> '*' then
		update_columns = 'OF ' || source_columns; 
	end if;

    perform syncdt.execute('
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE %s OR DELETE ON %I.%I
        FOR EACH ROW
        EXECUTE FUNCTION syncdt._trigger_on_source_changed(%L, %L, %L, %L);',
        trigger_name, update_columns, 
		source_schema, source_name,
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
	IF TG_OP = 'UPDATE' and OLD = NEW then
		return NULL;
	END IF;

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
		expold = syncdt.solve_expression(rec.source_exp, OLD);
	end if;

	if TG_OP = 'INSERT' or TG_OP = 'UPDATE' then
		expnew = syncdt.solve_expression(rec.source_exp, NEW);
	end if;

	if rec.wait_until is not null then
	    --insert into syncdt._temp_log(message) values (format('wait_until: %s | Record: %s', rec.wait_until, rec));

		if expold is not null then
			expw_old = syncdt.solve_expression(rec.wait_until, OLD);
		end if;

		if expnew is not null then
			expw_new = syncdt.solve_expression(rec.wait_until, NEW);
		end if;
	end if;

    IF TG_OP = 'DELETE' THEN

	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expold, expw_old::timestamptz);

    ELSIF TG_OP = 'INSERT' THEN

	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expnew, expw_new::timestamptz);

    ELSIF TG_OP = 'UPDATE' THEN
	    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expold, expw_old::timestamptz);

		if (expold <> expnew) OR (expw_new <> expw_old) then 
	    	PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, rec.source_schema, rec.source_table, expnew, expw_new::timestamptz);
		end if;
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
		where (t.table_schema || '.' || t.table_name = notify_source_changed.derived_table OR 
			   t.table_schema = 'public' AND t.table_name = notify_source_changed.derived_table)
		  and (d.source_schema || '.' || d.source_table = notify_source_changed.source_table OR 
			   d.source_schema = 'public' AND d.source_table = notify_source_changed.source_table); 

	if not FOUND then
		raise exception 'Não foi identificada dependência entre as tabelas % e %', notify_source_changed.derived_table, notify_source_changed.source_table;
	end if;

	exp = syncdt.solve_expression(rec.source_exp, source_record);

    PERFORM syncdt._notify_source_changed(rec.derived_schema, rec.derived_table, rec.refresh_mode, rec.notification_mode, rec.target_columns, 
    	rec.source_schema, rec.source_table, exp, null);
END;
$$;




CREATE OR REPLACE FUNCTION syncdt._notify_source_changed(derived_schema text, derived_table text, refresh_mode text, notification_mode text, target_columns text, source_schema text, source_table text, source_exp text, wait_until timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
			SELECT _notify_source_changed.derived_schema, _notify_source_changed.derived_table, NOW(), sfilter, 
					_notify_source_changed.wait_until, _notify_source_changed.source_schema, _notify_source_changed.source_table
		WHERE NOT EXISTS (SELECT * FROM syncdt._refresh_queue q
		    WHERE q.derived_schema = _notify_source_changed.derived_schema AND q.derived_table = _notify_source_changed.derived_table
		      AND (q.wait_until IS NOT DISTINCT FROM _notify_source_changed.wait_until)
			  AND q.filter = sfilter AND q.processed_at IS NULL);

	elsif notification_mode = 'full' then

		raise exception 'notification_mode full temporariamente supensa';

	    INSERT INTO syncdt._refresh_queue (derived_schema, derived_table, triggered_at, filter, wait_until, source_schema, source_table)
	    VALUES (_notify_source_changed.derived_schema, _notify_source_changed.derived_table, NOW(), 
			sfilter, _notify_source_changed.wait_until, _notify_source_changed.source_schema, _notify_source_changed.source_table);

	else
		raise exception 'Modo de notificação desconhecido: %', notification_mode;
	end if;

	raise notice 'Notificação de mudança de %.% para %.% => %',  
		_notify_source_changed.source_schema, _notify_source_changed.source_table,
		_notify_source_changed.derived_schema, _notify_source_changed.derived_table, sfilter;

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
$function$
;



