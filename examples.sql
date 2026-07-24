

select syncdt.create_derived_table(
	table_name => 'tlm.resumo_leituras_tag_dia',
	query => 'select * from tlm.gerar_resumo_leituras_tag_dia',
	primary_key => 'dia, tag_id'
);


select syncdt.assign_dependency(
		derived_table => 'tlm.resumo_leituras_tag_dia',
		source_table => 'tlm.leitura_tag',
		target_columns => 'dia, tag_id',
		source_exp => '= (${select dref(${source.diahora})}, ${source.tag})',
		wait_until => $$${select dref(${source.diahora}) + interval '1 day'}$$
);


select syncdt.assign_dependency(
		derived_table => 'tlm.resumo_leituras_tag_dia',
		source_table => 'tlm.revisao_ponto',
		target_columns => 'tag_id',
		source_exp =>  $$in (${select string_agg(id::text, ', ') from tlm.tag where ponto = ${source.ponto}})$$
);


select syncdt.assign_dependency(
		derived_table => 'tlm.resumo_leituras_tag_dia',
		source_table => 'tlm.ponto',
		target_columns => 'tag_id',
		source_exp =>  $$in (${select string_agg(id::text, ', ') from tlm.tag where ponto = ${source.id}})$$,
		source_columns => 'dt_instalacao, tipo_medicao'
);


select * from tlm.tag

--select * from tlm.ponto

--DROP TRIGGER IF EXISTS syncdt_resumo_leituras_tag_dia_tlm_leitura_tag ON tlm.leitura_tag;

--select syncdt._create_refresh_trigger('tlm', 'resumo_leituras_tag_dia', 'tlm', 'leitura_tag') 
--select syncdt.refresh_derived_table('tlm.resumo_leituras_tag_dia')





