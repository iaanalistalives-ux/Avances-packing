-- =====================================================================
-- CJ03 · Control de Cajas: peso de caja vacía y de prenda controlados
-- (pedido de Christian, 06/11/2026: que no pongan lo que quieran)
--  · cada pesada de caja vacía se guarda aparte (caja_taras); la que usa el sistema es la
--    MEDIANA de las últimas N (TARA_MEDIANA_N) → una pesada mal escrita no la mueve
--  · rango contra la referencia (pesada actual, hoja o sistema): si se aleja más de
--    TARA_RANGO_PCT %, pide pesar otra vez + motivo y queda POR_REVISAR
--  · una pesada POR_REVISAR no cuenta mientras haya pesadas OK/APROBADA (si no hay ninguna, se usa para no trabar)
--  · TARA_APROBACION = 'SI' → toda pesada nueva (salvo la primera) espera aprobación
--    (hoy 'NO': registro libre durante las pruebas)
--  · peso de prenda: mismo rango y mediana de las últimas PRENDA_MEDIANA_N muestras
--  · caja que no está en el catálogo: se crea con origen MANUAL = «por confirmar» con Sistemas
-- Requiere CJ01. No borra nada. caja_api se modifica reemplazando solo las ramas
-- guardar_tipo y muestra_peso por llamadas a funciones nuevas, y agregando revisar_tara y
-- la lista de taras al tablero (ver bloque DO al final).
-- Exclusivo de Postgres: percentile_cont (en SQL Server: PERCENTILE_CONT ... OVER()).
-- =====================================================================

alter table caja_pesos add column if not exists fuera_rango boolean not null default false;
alter table caja_pesos add column if not exists motivo text;

create table if not exists caja_taras(
  id bigserial primary key,
  tipo_cod text not null references caja_tipos(codigo),
  peso_g numeric(10,1) not null check (peso_g > 0),
  referencia_g numeric(10,1),
  fuera_rango boolean not null default false,
  motivo text,
  estado text not null default 'OK' check (estado in ('OK','POR_REVISAR','APROBADA','RECHAZADA')),
  usuario text,
  fecha timestamptz not null default now(),
  revisado_por text,
  revisado_en timestamptz,
  nota_revision text
);
create index if not exists caja_taras_tipo on caja_taras(tipo_cod);
alter table caja_taras enable row level security;
drop policy if exists caja_taras_leer on caja_taras;
create policy caja_taras_leer on caja_taras for select to anon, authenticated using (true);

insert into caja_parametros(clave,valor,descripcion) values
 ('TARA_RANGO_PCT','15','% que puede alejarse una pesada (caja vacía o prenda) de su referencia sin pedir segunda pesada y motivo'),
 ('TARA_MEDIANA_N','3','Pesadas de caja vacía que se usan (mediana de las últimas N)'),
 ('PRENDA_MEDIANA_N','5','Muestras de peso de prenda que se usan (mediana de las últimas N)'),
 ('TARA_APROBACION','NO','SI = toda pesada nueva de caja vacía espera aprobación antes de usarse')
on conflict (clave) do nothing;

-- peso de caja vacía que usa el sistema = mediana de las últimas N pesadas OK/APROBADA;
-- si todavía no hay ninguna así (caja nueva o hoja equivocada), usa las POR_REVISAR para no trabar el trabajo
create or replace function caja_recalc_tara(p_tipo text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare n int := coalesce(nullif(caja_par('TARA_MEDIANA_N'),'')::int,3); v numeric; u text; f timestamptz; e text[] := array['OK','APROBADA'];
begin
  if not exists(select 1 from caja_taras where tipo_cod=p_tipo and estado = any(e)) then e := array['POR_REVISAR']; end if;
  select round(percentile_cont(0.5) within group (order by peso_g)::numeric,1) into v
    from (select peso_g from caja_taras where tipo_cod=p_tipo and estado = any(e) order by id desc limit n) x;
  select usuario, fecha into u, f from caja_taras where tipo_cod=p_tipo and estado = any(e) order by id desc limit 1;
  update caja_tipos set tara_g=v, tara_pesada_por=u, tara_pesada_en=f where codigo=p_tipo;
end $$;

-- peso por prenda = mediana del peso unitario de las últimas N muestras válidas
create or replace function caja_recalc_peso(p_barcode text) returns void
language plpgsql security definer set search_path to 'public' as $$
declare n int := coalesce(nullif(caja_par('PRENDA_MEDIANA_N'),'')::int,5);
begin
  update caja_codigos c set
    peso_unit_g = coalesce(
      (select round(percentile_cont(0.5) within group (order by u)::numeric,2)
         from (select peso_g/cantidad u from caja_pesos where barcode=p_barcode and valido and not fuera_rango order by id desc limit n) x),
      (select round(percentile_cont(0.5) within group (order by u)::numeric,2)
         from (select peso_g/cantidad u from caja_pesos where barcode=p_barcode and valido order by id desc limit n) x)),
    peso_prendas = coalesce((select sum(cantidad)::int from caja_pesos where barcode=p_barcode and valido),0)
  where c.barcode = p_barcode;
end $$;

-- guardar_tipo: pesar caja vacía (con rango, segunda pesada y motivo) o crear caja nueva por confirmar
create or replace function caja_guardar_tipo_(p jsonb, v_usuario text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_tipo text; v_tara numeric; t caja_tipos%rowtype; v_ref numeric; v_pct numeric; v_fuera boolean; v_est text; v_id bigint; v_nuevo boolean := false;
begin
  v_tipo := upper(regexp_replace(btrim(coalesce(p->>'codigo','')),'\s','','g'));
  if v_tipo = '' then return jsonb_build_object('ok',false,'error','Falta el código de la caja'); end if;
  v_tara := nullif(p->>'tara_g','')::numeric;
  if v_tara is not null and v_tara <= 0 then return jsonb_build_object('ok',false,'error','El peso de la caja vacía debe ser mayor que cero'); end if;
  select * into t from caja_tipos where codigo = v_tipo;
  if t.codigo is null then
    if coalesce(btrim(p->>'descripcion'),'')='' then
      return jsonb_build_object('ok',false,'error','Caja nueva: escribe la descripción y las medidas'); end if;
    insert into caja_tipos(codigo,descripcion,largo_cm,ancho_cm,alto_cm,origen,creado_por)
    values (v_tipo, upper(btrim(p->>'descripcion')), nullif(p->>'largo_cm','')::numeric, nullif(p->>'ancho_cm','')::numeric,
            nullif(p->>'alto_cm','')::numeric, 'MANUAL', v_usuario) returning * into t;
    v_nuevo := true;
    insert into caja_eventos(accion,detalle,usuario) values ('CAJA_NUEVA_POR_CONFIRMAR', p - 'usuario', v_usuario);
  elsif (p ? 'frecuente') or (p ? 'activo') then
    update caja_tipos set frecuente = coalesce((p->>'frecuente')::boolean, frecuente), activo = coalesce((p->>'activo')::boolean, activo),
      actualizado=now(), actualizado_por=v_usuario where codigo = v_tipo;
  end if;
  if v_tara is not null then
    v_ref := coalesce(t.tara_g, t.tara_hoja_g, t.tara_sistema_g);
    v_pct := coalesce(nullif(caja_par('TARA_RANGO_PCT'),'')::numeric,15);
    v_fuera := v_ref is not null and abs(v_tara - v_ref) > v_ref * v_pct / 100;
    if v_fuera and not coalesce((p->>'confirmado')::boolean,false) then
      return jsonb_build_object('ok',false,'fuera_rango',true,'referencia_g',v_ref,'codigo',v_tipo,
        'diferencia_pct',round(abs(v_tara-v_ref)/v_ref*100),
        'error','Ese peso se aleja '||round(abs(v_tara-v_ref)/v_ref*100)||' % de lo esperado para la caja '||v_tipo||' ('||trim(to_char(v_ref/1000,'FM990.00'))||' kg). Vuelve a pesar la caja vacía y, si se repite, escribe el motivo.');
    end if;
    if v_fuera and length(btrim(coalesce(p->>'motivo',''))) < 10 then
      return jsonb_build_object('ok',false,'fuera_rango',true,'referencia_g',v_ref,'codigo',v_tipo,'error','Escribe el motivo (al menos 10 letras): por qué esta caja pesa distinto'); end if;
    v_est := case when v_fuera then 'POR_REVISAR'
                  when upper(coalesce(caja_par('TARA_APROBACION'),'NO'))='SI'
                       and exists(select 1 from caja_taras where tipo_cod=v_tipo and estado in ('OK','APROBADA')) then 'POR_REVISAR'
                  else 'OK' end;
    insert into caja_taras(tipo_cod,peso_g,referencia_g,fuera_rango,motivo,estado,usuario)
    values (v_tipo, v_tara, v_ref, v_fuera, nullif(btrim(p->>'motivo'),''), v_est, v_usuario) returning id into v_id;
    perform caja_recalc_tara(v_tipo);
    insert into caja_eventos(accion,detalle,usuario) values ('TARA',
      jsonb_build_object('codigo',v_tipo,'peso_g',v_tara,'referencia_g',v_ref,'fuera_rango',v_fuera,'estado',v_est,'id',v_id,'motivo',p->>'motivo'), v_usuario);
  elsif not v_nuevo then
    insert into caja_eventos(accion,detalle,usuario) values ('TIPO_CAJA', p - 'usuario', v_usuario);
  end if;
  return jsonb_build_object('ok',true,'codigo',v_tipo,'nuevo',v_nuevo,'estado',v_est,
    'tara_g',(select tara_g from caja_tipos where codigo=v_tipo));
end $$;

create or replace function caja_revisar_tara_(p jsonb, v_usuario text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_dec text := upper(coalesce(p->>'decision','')); v_tipo text;
begin
  if v_dec not in ('APROBADA','RECHAZADA') then return jsonb_build_object('ok',false,'error','Decisión no válida'); end if;
  update caja_taras set estado=v_dec, revisado_por=v_usuario, revisado_en=now(), nota_revision=nullif(btrim(p->>'nota'),'')
   where id=(p->>'id')::bigint returning tipo_cod into v_tipo;
  if v_tipo is null then return jsonb_build_object('ok',false,'error','No existe esa pesada'); end if;
  perform caja_recalc_tara(v_tipo);
  insert into caja_eventos(accion,detalle,usuario) values ('REVISA_TARA', jsonb_build_object('id',p->>'id','decision',v_dec,'nota',p->>'nota'), v_usuario);
  return jsonb_build_object('ok',true,'tara_g',(select tara_g from caja_tipos where codigo=v_tipo));
end $$;

-- muestra de peso de prenda con rango, segunda pesada y motivo
create or replace function caja_muestra_(p jsonb, v_usuario text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare v_n int; v_peso numeric; v_ref numeric; v_unit numeric; v_pct numeric; v_fuera boolean;
begin
  if not exists(select 1 from caja_codigos where barcode = p->>'barcode') then return jsonb_build_object('ok',false,'error','No existe el código'); end if;
  v_n := nullif(p->>'cantidad','')::int; v_peso := nullif(p->>'peso_g','')::numeric;
  if coalesce(v_n,0) <= 0 or coalesce(v_peso,0) <= 0 then return jsonb_build_object('ok',false,'error','Cantidad y peso deben ser mayores que cero'); end if;
  v_unit := v_peso / v_n;
  select peso_unit_g into v_ref from caja_codigos where barcode = p->>'barcode';
  v_pct := coalesce(nullif(caja_par('TARA_RANGO_PCT'),'')::numeric,15);
  v_fuera := v_ref is not null and abs(v_unit - v_ref) > v_ref * v_pct / 100;
  if v_fuera and not coalesce((p->>'confirmado')::boolean,false) then
    return jsonb_build_object('ok',false,'fuera_rango',true,'referencia_g',v_ref,'unit_g',round(v_unit,1),
      'error','Cada prenda sale '||round(v_unit)||' g y lo registrado es '||round(v_ref)||' g ('||round(abs(v_unit-v_ref)/v_ref*100)||' % de diferencia). Pesa otra vez y, si se repite, escribe el motivo.');
  end if;
  if v_fuera and length(btrim(coalesce(p->>'motivo',''))) < 10 then
    return jsonb_build_object('ok',false,'fuera_rango',true,'error','Escribe el motivo (al menos 10 letras)'); end if;
  insert into caja_pesos(barcode,cantidad,peso_g,origen,usuario,fuera_rango,motivo)
  values (p->>'barcode', v_n, v_peso, 'MUESTRA', v_usuario, v_fuera, nullif(btrim(p->>'motivo'),''));
  perform caja_recalc_peso(p->>'barcode');
  return jsonb_build_object('ok',true,'peso_unit_g',(select peso_unit_g from caja_codigos where barcode=p->>'barcode'));
end $$;

create or replace function caja_taras_lista_() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]') from (
    select t.*, caja_nombre_(t.usuario) nombre, caja_nombre_(t.revisado_por) revisado_nombre
      from caja_taras t order by t.id desc limit 300) x
$$;

-- Ajuste de caja_api: reemplaza las ramas guardar_tipo y muestra_peso, agrega revisar_tara y taras al tablero
do $do$
declare s text; a int; b int;
begin
  s := pg_get_functiondef('caja_api(text,jsonb)'::regprocedure);
  a := strpos(s, $x$  elsif p_accion = 'muestra_peso' then$x$); b := strpos(s, $x$  elsif p_accion = 'anular_muestra' then$x$);
  if a = 0 or b = 0 or b < a then raise exception 'CJ03: no encontré la rama muestra_peso'; end if;
  s := left(s, a-1) || $x$  elsif p_accion = 'muestra_peso' then
    return caja_muestra_(p, v_usuario);
$x$ || substr(s, b);
  a := strpos(s, $x$  elsif p_accion = 'guardar_tipo' then$x$); b := strpos(s, $x$  elsif p_accion = 'guardar_parametro' then$x$);
  if a = 0 or b = 0 or b < a then raise exception 'CJ03: no encontré la rama guardar_tipo'; end if;
  s := left(s, a-1) || $x$  elsif p_accion = 'guardar_tipo' then
    return caja_guardar_tipo_(p, v_usuario);
  elsif p_accion = 'revisar_tara' then
    return caja_revisar_tara_(p, v_usuario);
$x$ || substr(s, b);
  if strpos(s, $x$'guardar_tipo','guardar_parametro');$x$) = 0 then raise exception 'CJ03: no encontré la lista de escritura'; end if;
  s := replace(s, $x$'guardar_tipo','guardar_parametro');$x$, $x$'guardar_tipo','guardar_parametro','revisar_tara');$x$);
  a := strpos(s, $x$      'tipos', coalesce((select jsonb_agg(to_jsonb(t) order by t.codigo) from caja_tipos t),'[]'),
      'parametros', (select jsonb_object_agg(clave, valor) from caja_parametros));
  elsif p_accion = 'packings_abiertos'$x$);
  if a = 0 then raise exception 'CJ03: no encontré el final de tablero'; end if;
  s := overlay(s placing $x$      'taras', caja_taras_lista_(),
$x$ from a for 0);
  execute s;
end $do$;
revoke all on function caja_api(text,jsonb) from public;
grant execute on function caja_api(text,jsonb) to anon, authenticated;
