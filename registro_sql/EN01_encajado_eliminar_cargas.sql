-- EN01 · Avances de Encajado: tabla "Lo ya subido" con eliminar (09/11/2026)
-- Registro de lo ejecutado en Supabase (lives-datos). No hace falta correrlo de nuevo.
-- Solo borra quien esté en encajado_quien_borra (Encajados). Cada borrado guarda copia en encajado_borrados.
-- Postgres-exclusivo a anotar para Sistemas: jsonb, auth.jwt() (vía enc_usuario_sesion), security definer.

create table if not exists public.encajado_quien_borra(
  usuario text primary key, nombre text);
alter table public.encajado_quien_borra enable row level security;
insert into public.encajado_quien_borra(usuario,nombre) values
  ('gcateriano','Encajados (carga)'),('gsotelo','Encajados (carga)'),('ctalepcio','Christian Talepcio')
on conflict do nothing;

create table if not exists public.encajado_borrados(
  id bigserial primary key, lote text, fecha timestamptz default now(),
  usuario text, tabla text, fila jsonb);
alter table public.encajado_borrados enable row level security;

-- Borra un avance (PO+color+OP) con su detalle y las cargas que queden vacías. Guarda copia.
create or replace function public.enc_borrar_avance_int(p_id int, p_usr text, p_nombre text, p_lote text)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare a encajado_avances%rowtype; n_det int := 0; n_car int := 0; v_ids text[];
begin
  select * into a from encajado_avances where id = p_id;
  if not found then return jsonb_build_object('ok', false, 'id', p_id, 'error', 'no existe'); end if;
  perform pg_advisory_xact_lock(hashtext('encajado_po|' || enc_clave_po(a.po)));
  insert into encajado_borrados(lote,usuario,tabla,fila) values (p_lote,p_usr,'encajado_avances',to_jsonb(a));
  insert into encajado_borrados(lote,usuario,tabla,fila)
    select p_lote,p_usr,'encajado_detalle',to_jsonb(d) from encajado_detalle d
     where enc_clave(d.grupo,d.estilo,d.po,d.color)=enc_clave(a.grupo,a.estilo,a.po,a.color)
       and coalesce(d.op,'')=coalesce(a.op,'');
  select coalesce(array_agg(distinct d.id_carga),'{}') into v_ids from encajado_detalle d
   where enc_clave(d.grupo,d.estilo,d.po,d.color)=enc_clave(a.grupo,a.estilo,a.po,a.color)
     and coalesce(d.op,'')=coalesce(a.op,'');
  delete from encajado_detalle d
   where enc_clave(d.grupo,d.estilo,d.po,d.color)=enc_clave(a.grupo,a.estilo,a.po,a.color)
     and coalesce(d.op,'')=coalesce(a.op,'');
  get diagnostics n_det = row_count;
  insert into encajado_borrados(lote,usuario,tabla,fila)
    select p_lote,p_usr,'encajado_cargas',to_jsonb(c) from encajado_cargas c
     where c.id_carga = any(v_ids) and not exists (select 1 from encajado_detalle d where d.id_carga=c.id_carga);
  delete from encajado_cargas c
   where c.id_carga = any(v_ids) and not exists (select 1 from encajado_detalle d where d.id_carga=c.id_carga);
  get diagnostics n_car = row_count;
  delete from encajado_avances where id = p_id;
  insert into encajado_historial(fecha,accion,usuario,nombre,grupo,estilo,po,color,detalle)
    values (now(),'ELIMINAR',p_usr,coalesce(nullif(p_nombre,''),p_usr),a.grupo,a.estilo,a.po,a.color,
      'OP '||coalesce(a.op,'')||' · Cantidad Lista = '||coalesce(a.cantidad_lista::text,'')||' · estatus cliente: '||coalesce(nullif(a.estatus_cliente,''),'sin marcar')||' · lote '||p_lote);
  return jsonb_build_object('ok', true, 'id', p_id, 'detalle', n_det, 'cargas', n_car);
end $f$;
revoke all on function public.enc_borrar_avance_int(int,text,text,text) from public, anon, authenticated;

create or replace function public.encajado_puede_borrar() returns jsonb
language sql stable security definer set search_path to 'public' as $f$
  select jsonb_build_object('puede', exists(select 1 from encajado_quien_borra where usuario = enc_usuario_sesion()))
$f$;

-- Lista de lo subido: una fila por PO + color + OP (lectura libre)
create or replace function public.encajado_cargas_lista() returns jsonb
language sql stable security definer set search_path to 'public' as $f$
  select coalesce(jsonb_agg(x order by x->>'fecha_carga' desc nulls last, (x->>'id')::int desc), '[]'::jsonb) from (
    select jsonb_build_object('id',a.id,'op',a.op,'grupo',a.grupo,'estilo',a.estilo,'po',a.po,'color',a.color,
      'pedido',a.cantidad_pedido,'lista',a.cantidad_lista,'estatus',a.estatus_cliente,
      'fecha_carga',(select max(d.fecha_carga_ts) from encajado_detalle d where enc_clave(d.grupo,d.estilo,d.po,d.color)=enc_clave(a.grupo,a.estilo,a.po,a.color) and coalesce(d.op,'')=coalesce(a.op,'')),
      'archivos',(select string_agg(distinct d.archivo,' · ') from encajado_detalle d where enc_clave(d.grupo,d.estilo,d.po,d.color)=enc_clave(a.grupo,a.estilo,a.po,a.color) and coalesce(d.op,'')=coalesce(a.op,'')),
      'talleres',(select string_agg(distinct d.taller,' · ') from encajado_detalle d where enc_clave(d.grupo,d.estilo,d.po,d.color)=enc_clave(a.grupo,a.estilo,a.po,a.color) and coalesce(d.op,'')=coalesce(a.op,''))) x
    from encajado_avances a) t
$f$;

-- Eliminar avances elegidos (solo Encajados)
create or replace function public.encajado_borrar_avances(p_ids int[], p_nombre text default null) returns jsonb
language plpgsql security definer set search_path to 'public' as $f$
declare v_usr text := enc_usuario_sesion(); v_lote text := 'DEL-'||to_char(now() at time zone 'America/Lima','YYYYMMDD-HH24MISS');
  i int; r jsonb; res jsonb := '[]'::jsonb;
begin
  if v_usr is null then raise exception 'No hay una sesión activa: cierra y vuelve a abrir la herramienta.'; end if;
  if not exists(select 1 from encajado_quien_borra where usuario = v_usr) then
    return jsonb_build_object('ok', false, 'error', 'Solo el equipo de Encajados puede eliminar avances.'); end if;
  if p_ids is null or array_length(p_ids,1) is null then return jsonb_build_object('ok', false, 'error', 'No elegiste ningún avance.'); end if;
  foreach i in array p_ids loop
    r := enc_borrar_avance_int(i, v_usr, p_nombre, v_lote); res := res || r;
  end loop;
  return jsonb_build_object('ok', true, 'lote', v_lote, 'resultado', res);
end $f$;

revoke all on function public.encajado_puede_borrar(), public.encajado_cargas_lista(), public.encajado_borrar_avances(int[],text) from public;
grant execute on function public.encajado_puede_borrar(), public.encajado_cargas_lista() to anon, authenticated;
grant execute on function public.encajado_borrar_avances(int[],text) to authenticated;
