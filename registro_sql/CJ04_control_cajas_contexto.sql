-- =====================================================================
-- CJ04 · Control de Cajas: contexto de códigos y pesos + grabar y contar en un escaneo
-- (pedido de Christian, 06/11/2026)
--  · caja_lineas toma sola la OP y el estilo LIVES desde ops (grupo + estilo cliente + color + PO)
--  · caja_codigos guarda dónde se grabó: cliente, grupo, PO, OP, estilo LIVES, lote, packing y caja
--  · caja_pesos guarda packing, caja, OP y cliente de cada pesada
--  · escanear con p.auto {estilo,color_cod,talla}: un código desconocido se graba con esa selección
--    y cuenta en el mismo escaneo
--  · peso de referencia: un código sin peso usa la mediana de otros códigos del mismo estilo, color
--    y talla (o estilo y talla) ya pesados, en vez de pedir muestra
-- Requiere CJ01 y CJ03. No borra nada. caja_api se ajusta por reemplazo de texto puntual (bloque DO).
-- =====================================================================

alter table caja_lineas add column if not exists op text;
alter table caja_lineas add column if not exists estilo_lives text;
alter table caja_codigos add column if not exists cliente_cod text;
alter table caja_codigos add column if not exists grupo text;
alter table caja_codigos add column if not exists po text;
alter table caja_codigos add column if not exists op text;
alter table caja_codigos add column if not exists estilo_lives text;
alter table caja_codigos add column if not exists lote text;
alter table caja_codigos add column if not exists packing_id text;
alter table caja_codigos add column if not exists caja_id_origen text;
alter table caja_pesos add column if not exists packing_id text;
alter table caja_pesos add column if not exists op text;
alter table caja_pesos add column if not exists cliente_cod text;

-- OP y estilo LIVES de una línea del packing, desde ops
create or replace function caja_op_de_(p_grupo text, p_estilo_cli text, p_color_cod text, p_color_nom text, p_pos text)
returns table(op text, estilo text) language sql stable security definer set search_path to 'public' as $$
  select o.op::text, o.estilo::text from ops o
   where upper(btrim(o.grupo)) = upper(btrim(coalesce(p_grupo,'')))
     and upper(btrim(o.e_cliente)) = upper(btrim(coalesce(p_estilo_cli,'')))
     and upper(btrim(o.color)) in (upper(btrim(coalesce(p_color_nom,''))), upper(btrim(coalesce(p_color_cod,''))))
   order by (upper(btrim(o.po)) = any(select upper(btrim(x)) from unnest(string_to_array(coalesce(p_pos,''),',')) x)) desc, o.op
   limit 1
$$;

create or replace function caja_lineas_op_() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare k caja_packings%rowtype; r record;
begin
  if new.op is null then
    select k2.* into k from caja_packings k2 join caja_cajas c on c.packing_id = k2.id where c.id = new.caja_id;
    select * into r from caja_op_de_(k.grupo, new.estilo, new.color_cod, new.color_nombre, k.po);
    new.op := r.op; new.estilo_lives := coalesce(new.estilo_lives, r.estilo);
  end if;
  return new;
end $$;
drop trigger if exists caja_lineas_op on caja_lineas;
create trigger caja_lineas_op before insert on caja_lineas for each row execute function caja_lineas_op_();

-- contexto de un código: de la línea de la caja que coincide (o de la caja, si no coincide)
create or replace function caja_contexto_codigo_(p_barcode text, p_caja text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare c caja_codigos%rowtype; k caja_packings%rowtype; l caja_lineas%rowtype;
begin
  if p_caja is null then return; end if;
  select * into c from caja_codigos where barcode = p_barcode;
  select k2.* into k from caja_packings k2 join caja_cajas x on x.packing_id = k2.id where x.id = p_caja;
  select * into l from caja_lineas where caja_id = p_caja and caja_norm(estilo)=caja_norm(c.estilo) and caja_norm(color_cod)=caja_norm(c.color_cod)
    order by (caja_norm(talla)=caja_norm(c.talla)) desc limit 1;
  update caja_codigos set cliente_cod=coalesce(cliente_cod,k.cliente_cod), grupo=coalesce(grupo,k.grupo), po=coalesce(po,k.po),
    op=coalesce(op,l.op), estilo_lives=coalesce(estilo_lives,l.estilo_lives), lote=coalesce(lote,l.lote),
    packing_id=coalesce(packing_id,k.id), caja_id_origen=coalesce(caja_id_origen,p_caja),
    color_nombre=coalesce(color_nombre,l.color_nombre)
  where barcode = p_barcode;
end $$;

-- contexto de cada pesada
create or replace function caja_pesos_ctx_() returns trigger
language plpgsql security definer set search_path to 'public' as $$
declare k caja_packings%rowtype; c caja_codigos%rowtype;
begin
  select * into c from caja_codigos where barcode = new.barcode;
  if new.caja_id is not null then
    select k2.* into k from caja_packings k2 join caja_cajas x on x.packing_id = k2.id where x.id = new.caja_id;
  end if;
  new.packing_id := coalesce(new.packing_id, k.id, c.packing_id);
  new.cliente_cod := coalesce(new.cliente_cod, k.cliente_cod, c.cliente_cod);
  new.op := coalesce(new.op, c.op);
  return new;
end $$;
drop trigger if exists caja_pesos_ctx on caja_pesos;
create trigger caja_pesos_ctx before insert on caja_pesos for each row execute function caja_pesos_ctx_();

-- peso de referencia de un código sin peso propio: mediana de otros códigos del mismo estilo+color+talla,
-- si no hay, del mismo estilo+talla
create or replace function caja_peso_ref_(p_barcode text) returns numeric
language sql stable security definer set search_path to 'public' as $$
  with c as (select * from caja_codigos where barcode = p_barcode)
  select coalesce(
    (select round(percentile_cont(0.5) within group (order by o.peso_unit_g)::numeric,2) from caja_codigos o, c
      where o.barcode <> c.barcode and o.peso_unit_g is not null and o.activo
        and caja_norm(coalesce(o.estilo_lives,o.estilo)) = caja_norm(coalesce(c.estilo_lives,c.estilo))
        and caja_norm(o.color_cod) = caja_norm(c.color_cod) and caja_norm(o.talla) = caja_norm(c.talla)),
    (select round(percentile_cont(0.5) within group (order by o.peso_unit_g)::numeric,2) from caja_codigos o, c
      where o.barcode <> c.barcode and o.peso_unit_g is not null and o.activo
        and caja_norm(coalesce(o.estilo_lives,o.estilo)) = caja_norm(coalesce(c.estilo_lives,c.estilo))
        and caja_norm(o.talla) = caja_norm(c.talla)))
$$;

-- muestra de peso: ahora también recibe la caja (contexto)
create or replace function caja_muestra_(p jsonb, v_usuario text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_n int; v_peso numeric; v_ref numeric; v_unit numeric; v_pct numeric; v_fuera boolean;
begin
  if not exists(select 1 from caja_codigos where barcode = p->>'barcode') then return jsonb_build_object('ok',false,'error','No existe el código'); end if;
  v_n := nullif(p->>'cantidad','')::int; v_peso := nullif(p->>'peso_g','')::numeric;
  if coalesce(v_n,0) <= 0 or coalesce(v_peso,0) <= 0 then return jsonb_build_object('ok',false,'error','Cantidad y peso deben ser mayores que cero'); end if;
  v_unit := v_peso / v_n;
  select coalesce(peso_unit_g, caja_peso_ref_(barcode)) into v_ref from caja_codigos where barcode = p->>'barcode';
  v_pct := coalesce(nullif(caja_par('TARA_RANGO_PCT'),'')::numeric,15);
  v_fuera := v_ref is not null and abs(v_unit - v_ref) > v_ref * v_pct / 100;
  if v_fuera and not coalesce((p->>'confirmado')::boolean,false) then
    return jsonb_build_object('ok',false,'fuera_rango',true,'referencia_g',v_ref,'unit_g',round(v_unit,1),
      'error','Cada prenda sale '||round(v_unit)||' g y lo registrado es '||round(v_ref)||' g ('||round(abs(v_unit-v_ref)/v_ref*100)||' % de diferencia). Pesa otra vez y, si se repite, escribe el motivo.');
  end if;
  if v_fuera and length(btrim(coalesce(p->>'motivo',''))) < 10 then
    return jsonb_build_object('ok',false,'fuera_rango',true,'error','Escribe el motivo (al menos 10 letras)'); end if;
  insert into caja_pesos(barcode,cantidad,peso_g,origen,usuario,fuera_rango,motivo,caja_id)
  values (p->>'barcode', v_n, v_peso, 'MUESTRA', v_usuario, v_fuera, nullif(btrim(p->>'motivo'),''), nullif(p->>'caja_id',''));
  perform caja_recalc_peso(p->>'barcode');
  return jsonb_build_object('ok',true,'peso_unit_g',(select peso_unit_g from caja_codigos where barcode=p->>'barcode'));
end $$;

-- detalle de caja: las líneas llevan OP y estilo LIVES
create or replace function caja_detalle_(p_caja text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'caja', to_jsonb(c) || jsonb_build_object(
        'packing', k.packing, 'cliente', k.cliente, 'destino', k.destino, 'grupo', k.grupo, 'po', k.po,
        'total_cajas', (select count(*) from caja_cajas z where z.packing_id = c.packing_id and z.estado <> 'ANULADA'),
        'tipo_medidas', t.descripcion, 'tara_g', t.tara_g, 'tara_sistema_g', t.tara_sistema_g, 'tara_hoja_g', t.tara_hoja_g,
        'cerrada_nombre', caja_nombre_(c.cerrada_por)),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'estilo', l.estilo, 'lote', l.lote, 'color_cod', l.color_cod, 'color_nombre', l.color_nombre,
        'talla', l.talla, 'cantidad', l.cantidad, 'op', l.op, 'estilo_lives', l.estilo_lives,
        'escaneadas', (select count(*) from caja_escaneos e where e.linea_id = l.id and e.resultado = 'OK' and not e.anulado))
        order by l.estilo, l.color_cod, l.id) from caja_lineas l where l.caja_id = c.id), '[]'),
    'escaneos', coalesce((select jsonb_agg(x order by x->>'fecha' desc) from (
        select jsonb_build_object('id', e.id, 'barcode', e.barcode, 'resultado', e.resultado, 'estilo', e.estilo,
               'color_cod', e.color_cod, 'talla', e.talla, 'fecha', e.fecha, 'anulado', e.anulado,
               'nombre', caja_nombre_(e.usuario)) x
          from caja_escaneos e where e.caja_id = c.id order by e.id desc limit 40) q), '[]'))
  from caja_cajas c join caja_packings k on k.id = c.packing_id
  left join caja_tipos t on t.codigo = c.tipo_cod
  where c.id = p_caja
$$;

-- ajuste de caja_api por reemplazo puntual
do $do$
declare s text; o text;
begin
  s := pg_get_functiondef('caja_api(text,jsonb)'::regprocedure);
  -- variable nueva
  o := 'v_numcajas int; v_cli text;';
  if strpos(s,o)=0 then raise exception 'CJ04: declaración'; end if;
  s := replace(s, o, 'v_numcajas int; v_cli text; v_auto boolean := false;');
  -- escanear: grabar y contar en un paso
  o := $x$    select * into v_cod from caja_codigos where barcode = v_bc;
    if v_cod.barcode is null or not v_cod.activo then$x$;
  if strpos(s,o)=0 then raise exception 'CJ04: escanear'; end if;
  s := replace(s, o, $x$    select * into v_cod from caja_codigos where barcode = v_bc;
    if v_cod.barcode is null and coalesce(btrim(p->'auto'->>'estilo'),'')<>'' and coalesce(btrim(p->'auto'->>'color_cod'),'')<>''
       and coalesce(btrim(p->'auto'->>'talla'),'')<>'' then
      insert into caja_codigos(barcode,estilo,color_cod,color_nombre,talla,creado_por)
      values (v_bc, upper(btrim(p->'auto'->>'estilo')), upper(btrim(p->'auto'->>'color_cod')), nullif(upper(btrim(p->'auto'->>'color_nombre')),''),
              upper(btrim(p->'auto'->>'talla')), v_usuario);
      perform caja_contexto_codigo_(v_bc, v_caja.id);
      insert into caja_eventos(packing_id,caja_id,barcode,accion,detalle,usuario)
      values (v_caja.packing_id, v_caja.id, v_bc, 'NUEVO_CODIGO_AUTO', p->'auto', v_usuario);
      select * into v_cod from caja_codigos where barcode = v_bc; v_auto := true;
    end if;
    if v_cod.barcode is null or not v_cod.activo then$x$);
  o := $x$    return jsonb_build_object('ok',true,'resultado',v_res,'codigo',to_jsonb(v_cod)) || caja_detalle_(v_caja.id);$x$;
  if strpos(s,o)=0 then raise exception 'CJ04: retorno escanear'; end if;
  s := replace(s, o, $x$    return jsonb_build_object('ok',true,'resultado',v_res,'codigo',to_jsonb(v_cod),'auto_grabado',v_auto) || caja_detalle_(v_caja.id);$x$);
  -- registrar_codigo: guarda el contexto
  o := $x$    insert into caja_eventos(caja_id,barcode,accion,detalle,usuario)
    values (nullif(p->>'caja_id',''), v_bc, 'NUEVO_CODIGO', p - 'usuario', v_usuario);$x$;
  if strpos(s,o)=0 then raise exception 'CJ04: registrar_codigo'; end if;
  s := replace(s, o, o || $x$
    perform caja_contexto_codigo_(v_bc, nullif(p->>'caja_id',''));$x$);
  -- pesar: un código sin peso propio usa el de referencia (mismo estilo, color y talla)
  o := $x$where e.caja_id=v_caja.id and e.resultado='OK' and not e.anulado and c.peso_unit_g is null;$x$;
  if strpos(s,o)=0 then raise exception 'CJ04: falta_peso'; end if;
  s := replace(s, o, $x$where e.caja_id=v_caja.id and e.resultado='OK' and not e.anulado and coalesce(c.peso_unit_g, caja_peso_ref_(c.barcode)) is null;$x$);
  o := $x$    select sum(c.peso_unit_g), min(c.peso_unit_g), avg(c.peso_unit_g) into v_esp, v_min, v_prom
      from caja_escaneos e join caja_codigos c on c.barcode=e.barcode$x$;
  if strpos(s,o)=0 then raise exception 'CJ04: esperado'; end if;
  s := replace(s, o, $x$    select sum(coalesce(c.peso_unit_g, caja_peso_ref_(c.barcode))), min(coalesce(c.peso_unit_g, caja_peso_ref_(c.barcode))), avg(coalesce(c.peso_unit_g, caja_peso_ref_(c.barcode))) into v_esp, v_min, v_prom
      from caja_escaneos e join caja_codigos c on c.barcode=e.barcode$x$);
  execute s;
end $do$;
revoke all on function caja_api(text,jsonb) from public;
grant execute on function caja_api(text,jsonb) to anon, authenticated;

-- completar OP y estilo LIVES en las líneas ya cargadas
update caja_lineas l set (op, estilo_lives) = (
  select r.op, r.estilo from caja_cajas c join caja_packings k on k.id = c.packing_id
         cross join lateral caja_op_de_(k.grupo, l.estilo, l.color_cod, l.color_nombre, k.po) r
   where c.id = l.caja_id)
 where l.op is null;
