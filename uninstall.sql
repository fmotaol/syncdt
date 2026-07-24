    DROP TABLE IF EXISTS syncdt._logs;
    DROP TABLE IF EXISTS syncdt._refresh_queue;
    DROP TABLE IF EXISTS syncdt._dependencies;
    DROP TABLE IF EXISTS syncdt._derived_tables;

    DROP TABLE IF EXISTS syncdt.refresh_queue_ux;

    RAISE NOTICE 'Tabelas e views internas do syncdt removidas com sucesso';

    RAISE exception 'falta excluir as funções';
    
	drop schema syncdt;
