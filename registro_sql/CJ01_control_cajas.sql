-- =====================================================================
-- CJ01 · Control de Cajas (escaneo por caja + peso)   prefijo caja_
-- Repo: Avances-packing · pantallas control_cajas.html, escaneo_cajas.html,
--       cierre_cajas.html
-- Exclusivo de Postgres (anotar para SQL Server):
--   · jsonb en la puerta caja_api (entrada y salida)
--   · regexp_replace con [^[:alnum:]] en caja_norm
--   · bigserial / secuencias, timestamptz, security definer
--   · RLS: lectura libre (anon) solo en Supabase
-- =====================================================================

create sequence if not exists caja_seq_packing;
create sequence if not exists caja_seq_caja;
create sequence if not exists caja_seq_tipo;

-- ---------- parámetros ----------
create table if not exists caja_parametros(
  clave text primary key,
  valor text not null,
  descripcion text
);
insert into caja_parametros(clave,valor,descripcion) values
 ('REGISTRO_LIBRE','SI','SI = cualquiera puede registrar durante las pruebas'),
 ('TOLERANCIA_FRACCION','0.5','Tolerancia de peso = esta fracción del peso de la prenda más liviana de la caja'),
 ('MARGEN_G','0','Gramos que se suman a la tolerancia (variación de bolsas y cinta)'),
 ('MUESTRA_PRENDAS','5','Prendas que se pesan juntas para aprender el peso de un código nuevo')
on conflict (clave) do nothing;

-- ---------- tipos de caja (tara) ----------
create table if not exists caja_tipos(
  codigo text primary key,                       -- TC-001
  medidas text not null unique,                  -- como viene en el packing: "24 X13 X12 PG"
  tara_g numeric(10,1),                          -- peso real de la caja vacía (se mide una vez)
  tara_sistema_g numeric(10,1),                  -- la que usa el sistema: (bruto-neto)/cajas
  activo boolean not null default true,
  creado timestamptz not null default now(),
  creado_por text,
  actualizado timestamptz,
  actualizado_por text
);

-- ---------- códigos de barra aprendidos ----------
create table if not exists caja_codigos(
  barcode text primary key,
  estilo text not null,
  color_cod text not null,
  color_nombre text,
  talla text not null,
  peso_unit_g numeric(10,2),                     -- Σ peso ÷ Σ prendas de sus muestras válidas
  peso_prendas int not null default 0,           -- prendas usadas para el peso
  verificado boolean not null default false,
  verificado_por text,
  verificado_en timestamptz,
  activo boolean not null default true,
  creado timestamptz not null default now(),
  creado_por text,
  actualizado timestamptz,
  actualizado_por text
);

create table if not exists caja_pesos(
  id bigserial primary key,
  barcode text not null references caja_codigos(barcode),
  cantidad int not null check (cantidad > 0),
  peso_g numeric(10,1) not null check (peso_g > 0),
  origen text not null check (origen in ('MUESTRA','CAJA')),
  caja_id text,
  usuario text,
  fecha timestamptz not null default now(),
  valido boolean not null default true
);

-- ---------- packings ----------
create table if not exists caja_packings(
  id text primary key,                           -- CPK-000001
  packing text not null,                         -- número del sistema (ej. 21380)
  cliente_cod text,                              -- cat_clientes.prefijo si cruza
  cliente text,
  destino text,
  descripcion text,
  grupo text,
  po text,
  peso_neto_kg numeric(12,2),                    -- declarado en el packing del sistema
  peso_bruto_kg numeric(12,2),
  archivo text,
  estado text not null default 'ABIERTO' check (estado in ('ABIERTO','CERRADO','ANULADO')),
  creado timestamptz not null default now(),
  creado_por text,
  anulado_en timestamptz,
  anulado_por text,
  motivo_anula text
);
create unique index if not exists caja_packings_vivo on caja_packings(packing) where estado <> 'ANULADO';

create table if not exists caja_cajas(
  id text primary key,                           -- CJ-000001 (va en el código de barras de la etiqueta)
  packing_id text not null references caja_packings(id),
  numero int not null,
  tipo_cod text references caja_tipos(codigo),
  estado text not null default 'PENDIENTE'
    check (estado in ('PENDIENTE','EN_PROCESO','ESCANEADA','OBSERVADA','CERRADA','ANULADA')),
  peso_bruto_g numeric(10,1),
  peso_esperado_g numeric(10,1),
  tolerancia_g numeric(10,1),
  peso_resultado text check (peso_resultado in ('OK','FUERA','REFERENCIA','APROBADO_CON_MOTIVO')),
  peso_origen text check (peso_origen in ('BALANZA','DIGITADO')),   -- hoy siempre DIGITADO (la balanza no tiene salida de datos)
  peso_motivo text,
  escaneada_en timestamptz,
  cerrada_en timestamptz,
  cerrada_por text,
  actualizado timestamptz not null default now(),
  unique(packing_id, numero)
);

create table if not exists caja_lineas(
  id bigserial primary key,
  caja_id text not null references caja_cajas(id),
  estilo text not null,
  lote text,
  color_cod text not null,
  color_nombre text,
  talla text not null,
  cantidad int not null check (cantidad > 0)
);
create index if not exists caja_lineas_caja on caja_lineas(caja_id);

create table if not exists caja_escaneos(
  id bigserial primary key,
  caja_id text not null references caja_cajas(id),
  linea_id bigint references caja_lineas(id),
  barcode text not null,
  resultado text not null check (resultado in ('OK','SOBRA','NO_CORRESPONDE','NUEVO')),
  estilo text, color_cod text, talla text,       -- foto del código al escanear
  token text unique,
  usuario text,
  fecha timestamptz not null default now(),
  anulado boolean not null default false,
  anulado_por text,
  anulado_en timestamptz
);
create index if not exists caja_escaneos_caja on caja_escaneos(caja_id);

create table if not exists caja_eventos(
  id bigserial primary key,
  packing_id text,
  caja_id text,
  barcode text,
  accion text not null,
  detalle jsonb,
  usuario text,
  fecha timestamptz not null default now()
);
create index if not exists caja_eventos_caja on caja_eventos(caja_id);

-- ---------- lectura libre en Supabase (en SQL Server: exige usuario) ----------
do $$ declare t text; begin
  foreach t in array array['caja_parametros','caja_tipos','caja_codigos','caja_pesos','caja_packings',
                           'caja_cajas','caja_lineas','caja_escaneos','caja_eventos'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t||'_leer', t);
    execute format('create policy %I on %I for select to anon, authenticated using (true)', t||'_leer', t);
  end loop;
end $$;

-- =====================================================================
-- Funciones de apoyo
-- =====================================================================
create or replace function caja_norm(v text) returns text
language sql immutable as $$
  select regexp_replace(upper(btrim(coalesce(v,''))), '[^[:alnum:]]', '', 'g')
$$;

create or replace function caja_par(p_clave text) returns text
language sql stable security definer set search_path to 'public' as $$
  select valor from caja_parametros where clave = p_clave
$$;

create or replace function caja_supervision_(p_usuario text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select lower(btrim(coalesce(p_usuario,''))) = 'rcamogliano'
      or exists(select 1 from perfiles where user_id::text = auth.uid()::text and lower(btrim(usuario)) = 'rcamogliano')
$$;

create or replace function caja_puede(p_usuario text default null) returns boolean
language plpgsql stable security definer set search_path to 'public' as $$
begin
  if caja_supervision_(p_usuario) then return false; end if;
  if lower(btrim(coalesce(p_usuario,''))) = 'ctalepcio' then return true; end if;
  return upper(coalesce(caja_par('REGISTRO_LIBRE'),'NO')) = 'SI';
end $$;

create or replace function caja_nombre_(p_usuario text) returns text
language sql stable security definer set search_path to 'public' as $$
  select upper(btrim(coalesce(nombre_sistemas(coalesce(
           public.mi_nombre(),
           (select nullif(btrim(nombre),'') from perfiles where lower(btrim(usuario)) = lower(btrim(p_usuario)) limit 1),
           nullif(btrim(p_usuario),''))), p_usuario, '')))
$$;

-- peso unitario = Σ peso ÷ Σ prendas (ponderado), solo muestras válidas
create or replace function caja_recalc_peso(p_barcode text) returns void
language sql security definer set search_path to 'public' as $$
  update caja_codigos c set
    peso_unit_g = x.u, peso_prendas = coalesce(x.n,0)
  from (select sum(peso_g)/nullif(sum(cantidad),0) u, sum(cantidad)::int n
          from caja_pesos where barcode = p_barcode and valido) x
  where c.barcode = p_barcode
$$;

-- estado de avance de una caja (escaneadas vs requeridas por línea)
create or replace function caja_detalle_(p_caja text) returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object(
    'caja', to_jsonb(c) || jsonb_build_object(
        'packing', k.packing, 'cliente', k.cliente, 'destino', k.destino, 'grupo', k.grupo, 'po', k.po,
        'total_cajas', (select count(*) from caja_cajas z where z.packing_id = c.packing_id and z.estado <> 'ANULADA'),
        'tipo_medidas', t.medidas, 'tara_g', t.tara_g, 'tara_sistema_g', t.tara_sistema_g,
        'cerrada_nombre', caja_nombre_(c.cerrada_por)),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'estilo', l.estilo, 'lote', l.lote, 'color_cod', l.color_cod, 'color_nombre', l.color_nombre,
        'talla', l.talla, 'cantidad', l.cantidad,
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

-- =====================================================================
-- Puerta única caja_api(accion, datos) → jsonb
-- =====================================================================
create or replace function caja_api(p_accion text, p jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_usuario text := nullif(btrim(coalesce(p->>'usuario','')),'');
  v_caja caja_cajas%rowtype; v_cod caja_codigos%rowtype; v_lin caja_lineas%rowtype;
  v_id text; v_pk text; v_tipo text; v_n int; v_req int; v_res text; v_ok int;
  v_tara numeric; v_esp numeric; v_tol numeric; v_min numeric; v_peso numeric; v_dif numeric;
  v_falta jsonb; v_bc text; v_cnt int; v_prom numeric; r record; x jsonb; v_numcajas int;
  f_escritura boolean := p_accion in ('guardar_packing','anular_packing','escanear','quitar','registrar_codigo',
     'corregir_codigo','verificar_codigo','muestra_peso','anular_muestra','pesar','aprobar_con_motivo','reabrir',
     'guardar_tipo','guardar_parametro');
begin
  if f_escritura and not caja_puede(v_usuario) then
    return jsonb_build_object('ok',false,'error', case when caja_supervision_(v_usuario)
      then 'Modo supervisión: puedes ver todo, pero no se guarda nada' else 'No tienes permiso para registrar en Control de Cajas' end);
  end if;

  -- ------------------------------------------------------------ lectura
  if p_accion = 'inicio' then
    return jsonb_build_object('ok',true,
      'puede', caja_puede(v_usuario), 'supervision', caja_supervision_(v_usuario),
      'nombre', nullif(caja_nombre_(v_usuario),''),
      'parametros', (select jsonb_object_agg(clave, valor) from caja_parametros),
      'tipos', coalesce((select jsonb_agg(to_jsonb(t) order by t.codigo) from caja_tipos t),'[]'),
      'clientes', coalesce((select jsonb_agg(jsonb_build_object('prefijo',prefijo,'cliente',cliente)) from cat_clientes),'[]'));

  elsif p_accion = 'tablero' then
    return jsonb_build_object('ok',true,
      'packings', coalesce((select jsonb_agg(q order by q->>'creado' desc) from (
         select to_jsonb(k) || jsonb_build_object(
           'creado_nombre', caja_nombre_(k.creado_por),
           'cajas', (select count(*) from caja_cajas c where c.packing_id=k.id and c.estado<>'ANULADA'),
           'cerradas', (select count(*) from caja_cajas c where c.packing_id=k.id and c.estado='CERRADA'),
           'observadas', (select count(*) from caja_cajas c where c.packing_id=k.id and c.estado='OBSERVADA'),
           'por_pesar', (select count(*) from caja_cajas c where c.packing_id=k.id and c.estado='ESCANEADA'),
           'en_proceso', (select count(*) from caja_cajas c where c.packing_id=k.id and c.estado='EN_PROCESO'),
           'requeridas', (select coalesce(sum(l.cantidad),0) from caja_lineas l join caja_cajas c on c.id=l.caja_id where c.packing_id=k.id and c.estado<>'ANULADA'),
           'escaneadas', (select count(*) from caja_escaneos e join caja_cajas c on c.id=e.caja_id where c.packing_id=k.id and c.estado<>'ANULADA' and e.resultado='OK' and not e.anulado),
           'alertas', (select count(*) from caja_escaneos e join caja_cajas c on c.id=e.caja_id where c.packing_id=k.id and e.resultado in ('SOBRA','NO_CORRESPONDE')),
           'peso_real_kg', (select round(sum(c.peso_bruto_g)/1000.0,2) from caja_cajas c where c.packing_id=k.id and c.estado='CERRADA'),
           'neto_real_kg', (select round(sum(c.peso_bruto_g - coalesce(t.tara_g,0))/1000.0,2) from caja_cajas c left join caja_tipos t on t.codigo=c.tipo_cod where c.packing_id=k.id and c.estado='CERRADA')
         ) q from caja_packings k) z), '[]'),
      'cajas', coalesce((select jsonb_agg(jsonb_build_object(
           'id',c.id,'packing_id',c.packing_id,'packing',k.packing,'cliente',k.cliente,'grupo',k.grupo,'po',k.po,
           'numero',c.numero,'estado',c.estado,'peso_bruto_g',c.peso_bruto_g,'peso_esperado_g',c.peso_esperado_g,
           'tolerancia_g',c.tolerancia_g,'peso_resultado',c.peso_resultado,'peso_origen',c.peso_origen,'peso_motivo',c.peso_motivo,
           'cerrada_en',c.cerrada_en,'cerrada_nombre',caja_nombre_(c.cerrada_por),'actualizado',c.actualizado,'medidas',t.medidas,
           'requeridas',(select coalesce(sum(cantidad),0) from caja_lineas l where l.caja_id=c.id),
           'escaneadas',(select count(*) from caja_escaneos e where e.caja_id=c.id and e.resultado='OK' and not e.anulado),
           'alertas',(select count(*) from caja_escaneos e where e.caja_id=c.id and e.resultado in ('SOBRA','NO_CORRESPONDE')))
           order by c.actualizado desc)
         from caja_cajas c join caja_packings k on k.id=c.packing_id left join caja_tipos t on t.codigo=c.tipo_cod
         where k.estado<>'ANULADO'), '[]'),
      'codigos', coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object('creado_nombre',caja_nombre_(c.creado_por),
           'verificado_nombre',caja_nombre_(c.verificado_por)) order by c.creado desc) from caja_codigos c), '[]'),
      'tipos', coalesce((select jsonb_agg(to_jsonb(t) order by t.codigo) from caja_tipos t),'[]'),
      'parametros', (select jsonb_object_agg(clave, valor) from caja_parametros));

  elsif p_accion = 'packings_abiertos' then
    return jsonb_build_object('ok',true,'packings', coalesce((select jsonb_agg(jsonb_build_object(
        'id',k.id,'packing',k.packing,'cliente',k.cliente,'destino',k.destino,'grupo',k.grupo,'po',k.po,
        'cajas',(select count(*) from caja_cajas c where c.packing_id=k.id and c.estado<>'ANULADA'),
        'cerradas',(select count(*) from caja_cajas c where c.packing_id=k.id and c.estado='CERRADA')) order by k.creado desc)
      from caja_packings k where k.estado='ABIERTO'),'[]'));

  elsif p_accion = 'cajas_packing' then
    return jsonb_build_object('ok',true,'cajas', coalesce((select jsonb_agg(jsonb_build_object(
        'id',c.id,'numero',c.numero,'estado',c.estado,'medidas',t.medidas,
        'requeridas',(select coalesce(sum(cantidad),0) from caja_lineas l where l.caja_id=c.id),
        'escaneadas',(select count(*) from caja_escaneos e where e.caja_id=c.id and e.resultado='OK' and not e.anulado),
        'resumen',(select string_agg(l.estilo||' '||coalesce(l.color_nombre,l.color_cod)||' '||l.talla||'×'||l.cantidad, ' · ' order by l.id) from caja_lineas l where l.caja_id=c.id))
        order by c.numero) from caja_cajas c left join caja_tipos t on t.codigo=c.tipo_cod
        where c.packing_id = p->>'packing_id' and c.estado<>'ANULADA'),'[]'));

  elsif p_accion = 'caja' then
    x := caja_detalle_(p->>'caja_id');
    if x is null then return jsonb_build_object('ok',false,'error','No existe la caja'); end if;
    return jsonb_build_object('ok',true) || x;

  elsif p_accion = 'por_pesar' then
    return jsonb_build_object('ok',true,'cajas', coalesce((select jsonb_agg(jsonb_build_object(
        'id',c.id,'numero',c.numero,'estado',c.estado,'packing',k.packing,'cliente',k.cliente,'grupo',k.grupo,'po',k.po,
        'total_cajas',(select count(*) from caja_cajas z where z.packing_id=c.packing_id and z.estado<>'ANULADA'),
        'escaneada_en',c.escaneada_en) order by c.escaneada_en desc nulls last)
      from caja_cajas c join caja_packings k on k.id=c.packing_id
      where c.estado in ('ESCANEADA','OBSERVADA') and k.estado='ABIERTO'),'[]'));

  -- ------------------------------------------------------------ packings
  elsif p_accion = 'guardar_packing' then
    if coalesce(btrim(p->>'packing'),'') = '' then return jsonb_build_object('ok',false,'error','Falta el número de packing'); end if;
    if jsonb_array_length(coalesce(p->'cajas','[]')) = 0 then return jsonb_build_object('ok',false,'error','El archivo no trae cajas'); end if;
    if exists(select 1 from caja_packings where packing = btrim(p->>'packing') and estado <> 'ANULADO') then
      return jsonb_build_object('ok',false,'error','El packing '||btrim(p->>'packing')||' ya está cargado. Si cambió, anúlalo primero (solo si aún no tiene escaneos).');
    end if;
    v_pk := 'CPK-'||lpad(nextval('caja_seq_packing')::text,6,'0');
    insert into caja_packings(id,packing,cliente_cod,cliente,destino,descripcion,grupo,po,peso_neto_kg,peso_bruto_kg,archivo,creado_por)
    values (v_pk, btrim(p->>'packing'),
      (select prefijo from cat_clientes where caja_norm(cliente)=caja_norm(p->>'cliente') or caja_norm(prefijo)=caja_norm(p->>'grupo_prefijo') limit 1),
      nullif(btrim(p->>'cliente'),''), nullif(btrim(p->>'destino'),''), nullif(btrim(p->>'descripcion'),''),
      nullif(btrim(p->>'grupo'),''), nullif(btrim(p->>'po'),''),
      nullif(p->>'peso_neto_kg','')::numeric, nullif(p->>'peso_bruto_kg','')::numeric,
      nullif(btrim(p->>'archivo'),''), v_usuario);
    v_numcajas := jsonb_array_length(p->'cajas');
    for x in select * from jsonb_array_elements(p->'cajas') loop
      v_tipo := null;
      if coalesce(btrim(x->>'medidas'),'') <> '' then
        select codigo into v_tipo from caja_tipos where caja_norm(medidas) = caja_norm(x->>'medidas');
        if v_tipo is null then
          v_tipo := 'TC-'||lpad(nextval('caja_seq_tipo')::text,3,'0');
          insert into caja_tipos(codigo,medidas,tara_sistema_g,creado_por)
          values (v_tipo, upper(btrim(x->>'medidas')),
            case when nullif(p->>'peso_bruto_kg','') is not null and nullif(p->>'peso_neto_kg','') is not null
                      and (p->>'peso_bruto_kg')::numeric > (p->>'peso_neto_kg')::numeric
                 then round(((p->>'peso_bruto_kg')::numeric - (p->>'peso_neto_kg')::numeric)*1000/v_numcajas,1) end,
            v_usuario);
        end if;
      end if;
      v_id := 'CJ-'||lpad(nextval('caja_seq_caja')::text,6,'0');
      insert into caja_cajas(id,packing_id,numero,tipo_cod) values (v_id, v_pk, (x->>'numero')::int, v_tipo);
      insert into caja_lineas(caja_id,estilo,lote,color_cod,color_nombre,talla,cantidad)
      select v_id, upper(btrim(l->>'estilo')), nullif(btrim(l->>'lote'),''), upper(btrim(l->>'color_cod')),
             nullif(upper(btrim(l->>'color_nombre')),''), upper(btrim(l->>'talla')), (l->>'cantidad')::int
        from jsonb_array_elements(x->'lineas') l where coalesce((l->>'cantidad')::int,0) > 0;
    end loop;
    insert into caja_eventos(packing_id,accion,detalle,usuario)
    values (v_pk,'CARGA_PACKING', jsonb_build_object('packing',p->>'packing','cajas',v_numcajas,'archivo',p->>'archivo'), v_usuario);
    return jsonb_build_object('ok',true,'id',v_pk,'cajas',v_numcajas,
      'prendas',(select sum(l.cantidad) from caja_lineas l join caja_cajas c on c.id=l.caja_id where c.packing_id=v_pk));

  elsif p_accion = 'anular_packing' then
    if length(btrim(coalesce(p->>'motivo',''))) < 5 then return jsonb_build_object('ok',false,'error','Escribe el motivo'); end if;
    if exists(select 1 from caja_escaneos e join caja_cajas c on c.id=e.caja_id where c.packing_id=p->>'id' and e.resultado='OK' and not e.anulado) then
      return jsonb_build_object('ok',false,'error','Este packing ya tiene prendas escaneadas: no se puede anular. Quita los escaneos primero.');
    end if;
    update caja_packings set estado='ANULADO', anulado_en=now(), anulado_por=v_usuario, motivo_anula=btrim(p->>'motivo') where id=p->>'id' and estado<>'ANULADO';
    if not found then return jsonb_build_object('ok',false,'error','No existe o ya estaba anulado'); end if;
    update caja_cajas set estado='ANULADA', actualizado=now() where packing_id=p->>'id';
    insert into caja_eventos(packing_id,accion,detalle,usuario) values (p->>'id','ANULA_PACKING',jsonb_build_object('motivo',p->>'motivo'),v_usuario);
    return jsonb_build_object('ok',true);

  -- ------------------------------------------------------------ escaneo
  elsif p_accion = 'escanear' then
    v_bc := btrim(coalesce(p->>'barcode',''));
    if v_bc = '' then return jsonb_build_object('ok',false,'error','Código vacío'); end if;
    if coalesce(p->>'token','') <> '' then
      select resultado into v_res from caja_escaneos where token = p->>'token';
      if v_res is not null then return jsonb_build_object('ok',true,'resultado',v_res,'repetido',true) || caja_detalle_(p->>'caja_id'); end if;
    end if;
    select * into v_caja from caja_cajas where id = p->>'caja_id' for update;
    if v_caja.id is null then return jsonb_build_object('ok',false,'error','No existe la caja'); end if;
    if v_caja.estado = 'CERRADA' then return jsonb_build_object('ok',false,'error','La caja '||v_caja.numero||' ya está cerrada'); end if;
    if v_caja.estado = 'ANULADA' then return jsonb_build_object('ok',false,'error','La caja está anulada'); end if;
    select * into v_cod from caja_codigos where barcode = v_bc;
    if v_cod.barcode is null or not v_cod.activo then
      return jsonb_build_object('ok',true,'resultado','NUEVO','barcode',v_bc,'bloqueado', v_cod.barcode is not null);
    end if;
    select l.* into v_lin from caja_lineas l
      where l.caja_id = v_caja.id and caja_norm(l.estilo)=caja_norm(v_cod.estilo)
        and caja_norm(l.color_cod)=caja_norm(v_cod.color_cod) and caja_norm(l.talla)=caja_norm(v_cod.talla)
      order by (select count(*) from caja_escaneos e where e.linea_id=l.id and e.resultado='OK' and not e.anulado) - l.cantidad
      limit 1;
    if v_lin.id is null then v_res := 'NO_CORRESPONDE';
    else
      select count(*) into v_ok from caja_escaneos where linea_id = v_lin.id and resultado='OK' and not anulado;
      v_res := case when v_ok >= v_lin.cantidad then 'SOBRA' else 'OK' end;
    end if;
    insert into caja_escaneos(caja_id,linea_id,barcode,resultado,estilo,color_cod,talla,token,usuario)
    values (v_caja.id, case when v_res='OK' then v_lin.id end, v_bc, v_res, v_cod.estilo, v_cod.color_cod, v_cod.talla,
            nullif(p->>'token',''), v_usuario);
    -- ¿caja completa?
    select coalesce(sum(l.cantidad),0), coalesce(sum((select count(*) from caja_escaneos e where e.linea_id=l.id and e.resultado='OK' and not e.anulado)),0)
      into v_req, v_ok from caja_lineas l where l.caja_id = v_caja.id;
    update caja_cajas set
      estado = case when v_ok >= v_req and v_req > 0 then
                      case when estado='OBSERVADA' then 'OBSERVADA' else 'ESCANEADA' end
                    when estado in ('PENDIENTE','ESCANEADA') then 'EN_PROCESO' else estado end,
      escaneada_en = case when v_ok >= v_req and v_req > 0 then coalesce(escaneada_en, now()) else null end,
      actualizado = now()
    where id = v_caja.id;
    return jsonb_build_object('ok',true,'resultado',v_res,'codigo',to_jsonb(v_cod)) || caja_detalle_(v_caja.id);

  elsif p_accion = 'quitar' then
    select c.* into v_caja from caja_cajas c join caja_escaneos e on e.caja_id=c.id where e.id = (p->>'escaneo_id')::bigint for update of c;
    if v_caja.id is null then return jsonb_build_object('ok',false,'error','No existe el escaneo'); end if;
    if v_caja.estado = 'CERRADA' then return jsonb_build_object('ok',false,'error','La caja está cerrada: reábrela primero'); end if;
    update caja_escaneos set anulado=true, anulado_por=v_usuario, anulado_en=now()
      where id=(p->>'escaneo_id')::bigint and not anulado and resultado='OK';
    if not found then return jsonb_build_object('ok',false,'error','Ese escaneo no cuenta o ya fue quitado'); end if;
    update caja_cajas set estado='EN_PROCESO', escaneada_en=null, peso_bruto_g=null, peso_esperado_g=null, tolerancia_g=null,
      peso_resultado=null, peso_origen=null, peso_motivo=null, actualizado=now() where id=v_caja.id;
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'QUITA_PRENDA',jsonb_build_object('escaneo_id',p->>'escaneo_id'),v_usuario);
    return jsonb_build_object('ok',true) || caja_detalle_(v_caja.id);

  -- ------------------------------------------------------------ códigos
  elsif p_accion = 'registrar_codigo' then
    v_bc := btrim(coalesce(p->>'barcode',''));
    if v_bc = '' or coalesce(btrim(p->>'estilo'),'')='' or coalesce(btrim(p->>'color_cod'),'')='' or coalesce(btrim(p->>'talla'),'')='' then
      return jsonb_build_object('ok',false,'error','Faltan datos: estilo, color y talla'); end if;
    if exists(select 1 from caja_codigos where barcode = v_bc) then
      return jsonb_build_object('ok',false,'error','Ese código ya está registrado. Para cambiarlo, corrígelo en Control de Cajas › Códigos.'); end if;
    insert into caja_codigos(barcode,estilo,color_cod,color_nombre,talla,creado_por)
    values (v_bc, upper(btrim(p->>'estilo')), upper(btrim(p->>'color_cod')), nullif(upper(btrim(p->>'color_nombre')),''), upper(btrim(p->>'talla')), v_usuario);
    insert into caja_eventos(caja_id,barcode,accion,detalle,usuario)
    values (nullif(p->>'caja_id',''), v_bc, 'NUEVO_CODIGO', p - 'usuario', v_usuario);
    return jsonb_build_object('ok',true,'codigo',(select to_jsonb(c) from caja_codigos c where barcode=v_bc));

  elsif p_accion = 'corregir_codigo' then
    select * into v_cod from caja_codigos where barcode = p->>'barcode' for update;
    if v_cod.barcode is null then return jsonb_build_object('ok',false,'error','No existe el código'); end if;
    if length(btrim(coalesce(p->>'motivo',''))) < 5 then return jsonb_build_object('ok',false,'error','Escribe el motivo de la corrección'); end if;
    update caja_codigos set
      estilo = coalesce(nullif(upper(btrim(p->>'estilo')),''), estilo),
      color_cod = coalesce(nullif(upper(btrim(p->>'color_cod')),''), color_cod),
      color_nombre = coalesce(nullif(upper(btrim(p->>'color_nombre')),''), color_nombre),
      talla = coalesce(nullif(upper(btrim(p->>'talla')),''), talla),
      activo = coalesce((p->>'activo')::boolean, activo),
      verificado = false, verificado_por = null, verificado_en = null,
      actualizado = now(), actualizado_por = v_usuario
    where barcode = v_cod.barcode;
    insert into caja_eventos(barcode,accion,detalle,usuario)
    values (v_cod.barcode,'CORRIGE_CODIGO', jsonb_build_object('antes',to_jsonb(v_cod),'despues',(select to_jsonb(c) from caja_codigos c where barcode=v_cod.barcode),'motivo',p->>'motivo'), v_usuario);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'verificar_codigo' then
    update caja_codigos set verificado=true, verificado_por=v_usuario, verificado_en=now() where barcode = p->>'barcode';
    if not found then return jsonb_build_object('ok',false,'error','No existe el código'); end if;
    insert into caja_eventos(barcode,accion,usuario) values (p->>'barcode','VERIFICA_CODIGO',v_usuario);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'muestra_peso' then
    if not exists(select 1 from caja_codigos where barcode = p->>'barcode') then return jsonb_build_object('ok',false,'error','No existe el código'); end if;
    v_n := nullif(p->>'cantidad','')::int; v_peso := nullif(p->>'peso_g','')::numeric;
    if coalesce(v_n,0) <= 0 or coalesce(v_peso,0) <= 0 then return jsonb_build_object('ok',false,'error','Cantidad y peso deben ser mayores que cero'); end if;
    insert into caja_pesos(barcode,cantidad,peso_g,origen,usuario) values (p->>'barcode', v_n, v_peso, 'MUESTRA', v_usuario);
    perform caja_recalc_peso(p->>'barcode');
    return jsonb_build_object('ok',true,'peso_unit_g',(select peso_unit_g from caja_codigos where barcode=p->>'barcode'));

  elsif p_accion = 'anular_muestra' then
    update caja_pesos set valido=false where id=(p->>'id')::bigint returning barcode into v_bc;
    if v_bc is null then return jsonb_build_object('ok',false,'error','No existe la muestra'); end if;
    perform caja_recalc_peso(v_bc);
    insert into caja_eventos(barcode,accion,detalle,usuario) values (v_bc,'ANULA_MUESTRA',jsonb_build_object('id',p->>'id'),v_usuario);
    return jsonb_build_object('ok',true);

  -- ------------------------------------------------------------ peso y cierre
  elsif p_accion = 'pesar' then
    select * into v_caja from caja_cajas where id = p->>'caja_id' for update;
    if v_caja.id is null then return jsonb_build_object('ok',false,'error','No existe la caja'); end if;
    if v_caja.estado not in ('ESCANEADA','OBSERVADA') then
      return jsonb_build_object('ok',false,'error', case v_caja.estado when 'CERRADA' then 'La caja ya está cerrada'
        else 'La caja aún no está completa: termina de escanearla' end); end if;
    v_peso := nullif(p->>'peso_g','')::numeric;
    if coalesce(v_peso,0) <= 0 then return jsonb_build_object('ok',false,'error','Peso no válido'); end if;
    v_tipo := coalesce(nullif(p->>'tipo_cod',''), v_caja.tipo_cod);
    select tara_g into v_tara from caja_tipos where codigo = v_tipo;
    if v_tipo is null then return jsonb_build_object('ok',false,'error','Elige el tipo de caja'); end if;
    if v_tara is null then return jsonb_build_object('ok',false,'falta_tara',true,'tipo_cod',v_tipo,
      'error','Esta medida de caja aún no tiene su peso vacía: pesa una caja vacía de este tipo'); end if;
    -- códigos sin peso
    select jsonb_agg(distinct jsonb_build_object('barcode',c.barcode,'estilo',c.estilo,'color',coalesce(c.color_nombre,c.color_cod),'talla',c.talla))
      into v_falta from caja_escaneos e join caja_codigos c on c.barcode=e.barcode
      where e.caja_id=v_caja.id and e.resultado='OK' and not e.anulado and c.peso_unit_g is null;
    select count(distinct e.barcode), count(*) into v_cnt, v_n from caja_escaneos e where e.caja_id=v_caja.id and e.resultado='OK' and not e.anulado;
    if v_falta is not null then
      if v_cnt = 1 then
        -- caja de un solo código y conteo verificado: el peso de esta caja enseña el peso de la prenda
        select barcode into v_bc from caja_escaneos where caja_id=v_caja.id and resultado='OK' and not anulado limit 1;
        if v_peso - v_tara <= 0 then return jsonb_build_object('ok',false,'error','El peso es menor que la caja vacía: revisa la balanza'); end if;
        insert into caja_pesos(barcode,cantidad,peso_g,origen,caja_id,usuario) values (v_bc, v_n, v_peso - v_tara, 'CAJA', v_caja.id, v_usuario);
        perform caja_recalc_peso(v_bc);
        update caja_cajas set tipo_cod=v_tipo, peso_bruto_g=v_peso, peso_esperado_g=null, tolerancia_g=null, peso_resultado='REFERENCIA',
          peso_origen=coalesce(p->>'origen','DIGITADO'), peso_motivo=nullif(btrim(p->>'motivo'),''),
          estado='CERRADA', cerrada_en=now(), cerrada_por=v_usuario, actualizado=now() where id=v_caja.id;
        insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'PESO',
          jsonb_build_object('peso_g',v_peso,'tara_g',v_tara,'resultado','REFERENCIA','origen',p->>'origen'),v_usuario);
        return jsonb_build_object('ok',true,'resultado','REFERENCIA') || caja_detalle_(v_caja.id);
      end if;
      return jsonb_build_object('ok',false,'falta_peso',v_falta,
        'error','Hay prendas sin peso conocido: pesa una muestra de cada una antes de pesar la caja');
    end if;
    select sum(c.peso_unit_g), min(c.peso_unit_g), avg(c.peso_unit_g) into v_esp, v_min, v_prom
      from caja_escaneos e join caja_codigos c on c.barcode=e.barcode
      where e.caja_id=v_caja.id and e.resultado='OK' and not e.anulado;
    v_esp := round(v_esp + v_tara, 1);
    v_tol := round(coalesce(caja_par('TOLERANCIA_FRACCION')::numeric,0.5) * v_min + coalesce(caja_par('MARGEN_G')::numeric,0), 1);
    v_dif := v_peso - v_esp;
    v_res := case when abs(v_dif) <= v_tol then 'OK' else 'FUERA' end;
    -- peso escrito a mano: si no cuadra, se pide volver a pesar y escribirlo otra vez antes de observar la caja
    if v_res = 'FUERA' and coalesce((p->>'confirmado')::boolean, false) = false then
      insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'PESO_PRIMERA_LECTURA',
        jsonb_build_object('peso_g',v_peso,'esperado_g',v_esp,'tolerancia_g',v_tol,'diferencia_g',v_dif),v_usuario);
      return jsonb_build_object('ok',false,'reconfirmar',true,'error','El peso no cuadra. Vuelve a poner la caja en la balanza y escribe el peso otra vez.');
    end if;
    update caja_cajas set tipo_cod=v_tipo, peso_bruto_g=v_peso, peso_esperado_g=v_esp, tolerancia_g=v_tol, peso_resultado=v_res,
      peso_origen=coalesce(p->>'origen','DIGITADO'), peso_motivo=nullif(btrim(p->>'motivo'),''),
      estado = case when v_res='OK' then 'CERRADA' else 'OBSERVADA' end,
      cerrada_en = case when v_res='OK' then now() end, cerrada_por = case when v_res='OK' then v_usuario end,
      actualizado=now() where id=v_caja.id;
    -- caja de un solo código que cuadra: afina el peso de la prenda
    if v_res='OK' and v_cnt=1 then
      select barcode into v_bc from caja_escaneos where caja_id=v_caja.id and resultado='OK' and not anulado limit 1;
      insert into caja_pesos(barcode,cantidad,peso_g,origen,caja_id,usuario) values (v_bc, v_n, v_peso - v_tara, 'CAJA', v_caja.id, v_usuario);
      perform caja_recalc_peso(v_bc);
    end if;
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'PESO',
      jsonb_build_object('peso_g',v_peso,'esperado_g',v_esp,'tolerancia_g',v_tol,'diferencia_g',v_dif,'resultado',v_res,'origen',p->>'origen','motivo',p->>'motivo'),v_usuario);
    return jsonb_build_object('ok',true,'resultado',v_res,'diferencia_g',v_dif,
      'prendas_estimadas', case when v_prom > 0 then round(v_dif / v_prom) end) || caja_detalle_(v_caja.id);

  elsif p_accion = 'aprobar_con_motivo' then
    if length(btrim(coalesce(p->>'motivo',''))) < 10 then return jsonb_build_object('ok',false,'error','Explica el motivo (al menos 10 letras)'); end if;
    update caja_cajas set estado='CERRADA', peso_resultado='APROBADO_CON_MOTIVO', peso_motivo=btrim(p->>'motivo'),
      cerrada_en=now(), cerrada_por=v_usuario, actualizado=now()
      where id=p->>'caja_id' and estado='OBSERVADA' returning * into v_caja;
    if v_caja.id is null then return jsonb_build_object('ok',false,'error','La caja no está observada'); end if;
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'APRUEBA_CON_MOTIVO',jsonb_build_object('motivo',p->>'motivo'),v_usuario);
    return jsonb_build_object('ok',true) || caja_detalle_(v_caja.id);

  elsif p_accion = 'reabrir' then
    if length(btrim(coalesce(p->>'motivo',''))) < 5 then return jsonb_build_object('ok',false,'error','Escribe el motivo'); end if;
    update caja_cajas set estado='EN_PROCESO', escaneada_en=null, cerrada_en=null, cerrada_por=null, peso_bruto_g=null,
      peso_esperado_g=null, tolerancia_g=null, peso_resultado=null, peso_origen=null, peso_motivo=null, actualizado=now()
      where id=p->>'caja_id' and estado in ('CERRADA','OBSERVADA','ESCANEADA') returning * into v_caja;
    if v_caja.id is null then return jsonb_build_object('ok',false,'error','La caja no se puede reabrir'); end if;
    update caja_pesos set valido=false where caja_id=v_caja.id and origen='CAJA';
    for r in select distinct barcode from caja_pesos where caja_id=v_caja.id loop perform caja_recalc_peso(r.barcode); end loop;
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'REABRE',jsonb_build_object('motivo',p->>'motivo'),v_usuario);
    return jsonb_build_object('ok',true);

  -- ------------------------------------------------------------ catálogos
  elsif p_accion = 'guardar_tipo' then
    v_tara := nullif(p->>'tara_g','')::numeric;
    if v_tara is not null and v_tara <= 0 then return jsonb_build_object('ok',false,'error','La tara debe ser mayor que cero'); end if;
    if coalesce(p->>'codigo','') <> '' then
      update caja_tipos set tara_g = coalesce(v_tara, tara_g), activo = coalesce((p->>'activo')::boolean, activo),
        actualizado=now(), actualizado_por=v_usuario where codigo = p->>'codigo';
      if not found then return jsonb_build_object('ok',false,'error','No existe el tipo'); end if;
      v_tipo := p->>'codigo';
    else
      if coalesce(btrim(p->>'medidas'),'')='' then return jsonb_build_object('ok',false,'error','Faltan las medidas'); end if;
      if exists(select 1 from caja_tipos where caja_norm(medidas)=caja_norm(p->>'medidas')) then return jsonb_build_object('ok',false,'error','Esa medida ya existe'); end if;
      v_tipo := 'TC-'||lpad(nextval('caja_seq_tipo')::text,3,'0');
      insert into caja_tipos(codigo,medidas,tara_g,creado_por) values (v_tipo, upper(btrim(p->>'medidas')), v_tara, v_usuario);
    end if;
    insert into caja_eventos(accion,detalle,usuario) values ('TIPO_CAJA', jsonb_build_object('codigo',v_tipo,'tara_g',v_tara), v_usuario);
    return jsonb_build_object('ok',true,'codigo',v_tipo);

  elsif p_accion = 'guardar_parametro' then
    if p->>'clave' not in ('TOLERANCIA_FRACCION','MARGEN_G','MUESTRA_PRENDAS') then
      return jsonb_build_object('ok',false,'error','Parámetro no editable'); end if;
    if p->>'clave' in ('TOLERANCIA_FRACCION','MARGEN_G','MUESTRA_PRENDAS') and (p->>'valor') !~ '^[0-9]+(\.[0-9]+)?$' then
      return jsonb_build_object('ok',false,'error','Escribe un número'); end if;
    update caja_parametros set valor = upper(btrim(p->>'valor')) where clave = p->>'clave';
    insert into caja_eventos(accion,detalle,usuario) values ('PARAMETRO', jsonb_build_object('clave',p->>'clave','valor',p->>'valor'), v_usuario);
    return jsonb_build_object('ok',true);

  elsif p_accion = 'eventos' then
    return jsonb_build_object('ok',true,'eventos', coalesce((select jsonb_agg(to_jsonb(e) || jsonb_build_object('nombre',caja_nombre_(e.usuario)) order by e.id desc)
      from (select * from caja_eventos where (p->>'caja_id' is null or caja_id = p->>'caja_id')
                                           and (p->>'barcode' is null or barcode = p->>'barcode')
            order by id desc limit 300) e),'[]'),
      'muestras', case when p->>'barcode' is not null then coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('nombre',caja_nombre_(m.usuario)) order by m.id desc)
        from caja_pesos m where barcode = p->>'barcode'),'[]') end);
  end if;

  return jsonb_build_object('ok',false,'error','Acción desconocida: '||coalesce(p_accion,''));
end $$;

revoke all on function caja_api(text,jsonb) from public;
grant execute on function caja_api(text,jsonb) to anon, authenticated;
