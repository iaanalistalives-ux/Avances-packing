-- =====================================================================================
-- EN03 · Avances de Packing: auditorías que vienen del aplicativo de Sistemas
-- Aplicado por Claude en Supabase (lives-datos) el 17/11/2026, con el «procede» de Christian.
-- ESTE ARCHIVO ES SOLO REGISTRO: NO SE EJECUTA (guardar sin Run).
--
-- Por qué: desde el 10/11/2026 las auditorías se registran en el aplicativo de Sistemas y ya
-- no llegan a la tabla `auditorias`. Christian descarga el Excel «Buscar auditorías» de ese
-- aplicativo, lo deja en Descargas y dice «sube auditorías»; Claude lo carga con
-- `carga/cargar_auditorias.py` + `encajado_aud_cargar`.
--
-- Qué se creó o cambió:
--   1. Tabla   encajado_aud_sistemas      (nueva; llave = ID de Sistemas; lectura libre)
--   2. Función encajado_aud_cargar        (nueva; agrega o actualiza por ID, nunca borra;
--                                          solo la ejecuta Claude desde su conexión)
--   3. Vista   encajado_aud_vivo          (ampliada: suma la tabla nueva)
--   4. Función encajado_auditorias_visor  (ampliada: suma la tabla nueva)
--   5. Carga de 116 auditorías (ID 000000005748 a 000000005863, del 10/11 al 17/11/2026).
--      Los datos no van en este archivo (son de la empresa): salen del Excel de Sistemas.
--
-- Reglas:
--   · Corte: solo entran ID >= 000000005748. Lo anterior ya está en `auditorias` con su lote.
--   · Proceso «Artes»: se guarda, pero no cuenta para el estatus.
--   · Una auditoría con varios PO o colores («Black, Navy») da estatus a cada combinación;
--     su lote no se reparte (cuenta 0 en el % auditado).
--   · Auditor y taller quedan como vienen de Sistemas (nombre completo y razón social).
--   · No se tocó `auditorias` ni `publico_final`: las demás herramientas quedan igual.
--
-- Probado: prueba que se deshace sola (nueva / actualizada / igual / anterior al corte);
-- después de cargar, la tabla coincide con el Excel campo por campo (116 filas, 0 diferencias,
-- suma de lote 52 718). Dashboard: 665 registros; con estatus pasó de 276 a 278.
--
-- A Sistemas (SQL Server): `string_to_array`/`unnest`/`cross join lateral` → STRING_SPLIT +
-- CROSS APPLY; `jsonb` → OPENJSON; `on conflict` → MERGE; `ilike` → LIKE con collation CI.
-- En SQL Server esta tabla no hace falta: las auditorías salen directo de su base.
-- =====================================================================================

-- 1. TABLA ---------------------------------------------------------------------------
create table public.encajado_aud_sistemas (
  id_sistemas text primary key check (id_sistemas ~ '^[0-9]+$'),
  fecha date not null, op text, proceso text, cliente text, grupo text, estilo text, po text, color text,
  lote numeric, muestra numeric, defectos numeric, taller text, auditor text, estado text, reprocesa_a text,
  archivo text, cargado_en timestamptz not null default now(), actualizado_en timestamptz not null default now());
alter table public.encajado_aud_sistemas enable row level security;
create policy lectura_libre on public.encajado_aud_sistemas for select to anon, authenticated using (true);
revoke all on public.encajado_aud_sistemas from anon, authenticated;
grant select on public.encajado_aud_sistemas to anon, authenticated;

-- 2. FUNCIÓN DE CARGA ----------------------------------------------------------------
-- p_filas: lista de filas, cada una una lista en este orden:
--   [id, fecha AAAA-MM-DD, op, proceso, cliente, grupo, estilo, po, color, lote, muestra, defectos,
--    taller, auditor, estado, reprocesa_a]
create or replace function public.encajado_aud_cargar(p_filas jsonb, p_archivo text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $f$
declare v_corte constant text := '000000005748'; v_n int; v_ign int; v_nuevas int; v_act int;
begin
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' then raise exception 'p_filas debe ser una lista de filas'; end if;
  with f as (
    select lpad(btrim(x->>0),12,'0') as id, (x->>1)::date as fecha, nullif(btrim(x->>2),'') as op, nullif(btrim(x->>3),'') as proceso,
           nullif(btrim(x->>4),'') as cliente, nullif(btrim(x->>5),'') as grupo, nullif(btrim(x->>6),'') as estilo,
           nullif(btrim(x->>7),'') as po, nullif(btrim(x->>8),'') as color,
           nullif(btrim(x->>9),'')::numeric as lote, nullif(btrim(x->>10),'')::numeric as muestra, nullif(btrim(x->>11),'')::numeric as defectos,
           nullif(btrim(x->>12),'') as taller, nullif(btrim(x->>13),'') as auditor, nullif(btrim(x->>14),'') as estado,
           nullif(btrim(x->>15),'') as reprocesa_a
      from jsonb_array_elements(p_filas) x
  ), up as (
    insert into encajado_aud_sistemas as t (id_sistemas, fecha, op, proceso, cliente, grupo, estilo, po, color, lote, muestra, defectos, taller, auditor, estado, reprocesa_a, archivo)
    select id, fecha, op, proceso, cliente, grupo, estilo, po, color, lote, muestra, defectos, taller, auditor, estado, reprocesa_a, p_archivo
      from f where id >= v_corte
    on conflict (id_sistemas) do update
       set fecha = excluded.fecha, op = excluded.op, proceso = excluded.proceso, cliente = excluded.cliente, grupo = excluded.grupo,
           estilo = excluded.estilo, po = excluded.po, color = excluded.color, lote = excluded.lote, muestra = excluded.muestra,
           defectos = excluded.defectos, taller = excluded.taller, auditor = excluded.auditor, estado = excluded.estado,
           reprocesa_a = excluded.reprocesa_a, archivo = excluded.archivo, actualizado_en = now()
     where (t.fecha, t.op, t.proceso, t.cliente, t.grupo, t.estilo, t.po, t.color, t.lote, t.muestra, t.defectos, t.taller, t.auditor, t.estado, t.reprocesa_a)
           is distinct from
           (excluded.fecha, excluded.op, excluded.proceso, excluded.cliente, excluded.grupo, excluded.estilo, excluded.po, excluded.color, excluded.lote, excluded.muestra, excluded.defectos, excluded.taller, excluded.auditor, excluded.estado, excluded.reprocesa_a)
    returning (xmax = 0) as nueva
  )
  select (select count(*) from f), (select count(*) from f where id < v_corte),
         count(*) filter (where nueva), count(*) filter (where not nueva)
    into v_n, v_ign, v_nuevas, v_act from up;
  return jsonb_build_object('ok', true, 'recibidas', v_n, 'nuevas', v_nuevas, 'actualizadas', v_act,
                            'iguales', v_n - v_ign - v_nuevas - v_act, 'anteriores_al_corte', v_ign,
                            'total_en_tabla', (select count(*) from encajado_aud_sistemas));
end $f$;
revoke all on function public.encajado_aud_cargar(jsonb, text) from public, anon, authenticated;

-- 3. VISTA encajado_aud_vivo (la primera mitad es la de antes, sin cambios; se agrega el UNION ALL)
create or replace view public.encajado_aud_vivo as
 SELECT fila_hoja,
    enc_clave(grupo, estilo, po, color) AS clave,
    enc_proceso(tipo_proceso) AS proceso,
    COALESCE(NULLIF(upper(btrim(COALESCE(int_ext, ''::text))), ''::text), '—'::text) AS int_ext,
    POSITION(('FINAL'::text) IN (upper(btrim(COALESCE(tipo_auditoria, ''::text))))) > 0 AS es_final,
    btrim(COALESCE(resultado, ''::text)) AS resultado,
    btrim(COALESCE(auditor, ''::text)) AS auditor,
        CASE
            WHEN upper(btrim(COALESCE(int_ext, ''::text))) = 'INTERNO'::text THEN 'LIVES (planta)'::text
            ELSE COALESCE(NULLIF(btrim(COALESCE(servicio, ''::text)), ''::text), '—'::text)
        END AS taller,
    COALESCE(lote, 0::numeric) AS lote,
    fecha,
    COALESCE(to_char(fecha::timestamp with time zone, 'DD/MM/YYYY'::text), ''::text) AS fecha_txt,
    registrado_en,
    (fecha::timestamp without time zone AT TIME ZONE 'America/Lima'::text) AS cuando
   FROM auditorias a
  WHERE origen = 'VIVO'::text AND btrim(COALESCE(estado, ''::text)) = 'VIGENTE'::text
 UNION ALL
 SELECT 1000000 + s.id_sistemas::integer AS fila_hoja,
    enc_clave(s.grupo, s.estilo, x.po, x.color) AS clave,
    enc_proceso(s.proceso) AS proceso,
        CASE WHEN s.proceso ILIKE '%intern%' THEN 'INTERNO'::text WHEN s.proceso ILIKE '%taller%' THEN 'EXTERNO'::text ELSE '—'::text END AS int_ext,
    true AS es_final,
    upper(btrim(COALESCE(s.estado, ''::text))) AS resultado,
    btrim(COALESCE(s.auditor, ''::text)) AS auditor,
        CASE WHEN s.proceso ILIKE '%intern%' THEN 'LIVES (planta)'::text
             ELSE COALESCE(NULLIF(btrim(COALESCE(s.taller, ''::text)), ''::text), '—'::text) END AS taller,
        CASE WHEN x.multi THEN 0::numeric ELSE COALESCE(s.lote, 0::numeric) END AS lote,
    s.fecha,
    COALESCE(to_char(s.fecha::timestamp with time zone, 'DD/MM/YYYY'::text), ''::text) AS fecha_txt,
    s.cargado_en AS registrado_en,
    (s.fecha::timestamp without time zone AT TIME ZONE 'America/Lima'::text) AS cuando
   FROM encajado_aud_sistemas s
   CROSS JOIN LATERAL (
     SELECT btrim(p.v) AS po, btrim(c.v) AS color,
            (cardinality(string_to_array(COALESCE(s.po, ''), ', ')) > 1 OR cardinality(string_to_array(COALESCE(s.color, ''), ', ')) > 1) AS multi
       FROM unnest(CASE WHEN COALESCE(s.po, '') = '' THEN ARRAY[''::text] ELSE string_to_array(s.po, ', ') END) p(v),
            unnest(CASE WHEN COALESCE(s.color, '') = '' THEN ARRAY[''::text] ELSE string_to_array(s.color, ', ') END) c(v)
   ) x
  WHERE COALESCE(s.proceso, '') NOT ILIKE 'artes%'
    AND upper(btrim(COALESCE(s.estado, ''))) IN ('APROBADO', 'RECHAZADO');

-- 4. FUNCIÓN encajado_auditorias_visor (cambia solo el bloque «m»: antes era
--    «select p.*, enc_fecha_iso(p.fecha) as f, kk1, kk2 from publico_final p»)
create or replace function public.encajado_auditorias_visor(p_meses integer default 4)
returns jsonb language sql stable security definer set search_path to 'public' as $f$
  with d as (   -- claves pedidas: PO completa y PO sin destino
    select id, enc_clave(grupo, estilo, po, color) as k1,
           enc_clave(grupo, estilo, enc_po_base(po), color) as k2
      from encajado_detalle
  ), q as (     -- si dos filas dan la misma clave, manda la última (igual que el script)
    select distinct on (k) k, k1 as destino
      from (select id, k1, k1 as k from d union all
            select id, k1, k2 from d where k2 <> k1) z
     where k1 <> '|||'
     order by k, id desc
  ), corte as (
    select to_char((now() at time zone 'America/Lima') - make_interval(months => p_meses),
                   'YYYY-MM-DD') as c
  ), m as (
    select p.id_auditoria, p.tipo, p.resultado, p.auditor, p.servicio, p.int_ext, p.lote, p.muestra,
           enc_fecha_iso(p.fecha) as f,
           enc_clave(p.grupo, p.estilo, p.po, p.color) as kk1,
           enc_clave(p.grupo, p.estilo, enc_po_base(p.po), p.color) as kk2
      from publico_final p
    union all   -- auditorías que vienen del aplicativo de Sistemas (tabla encajado_aud_sistemas)
    select 'S' || s.id_sistemas, regexp_replace(s.proceso, '\s*\(', ' ('), upper(btrim(coalesce(s.estado,''))), s.auditor, s.taller,
           case when s.proceso ilike '%intern%' then 'INTERNO' when s.proceso ilike '%taller%' then 'EXTERNO' else '' end,
           case when x.multi then 0 else s.lote end, s.muestra,
           to_char(s.fecha, 'YYYY-MM-DD'),
           enc_clave(s.grupo, s.estilo, x.po, x.color),
           enc_clave(s.grupo, s.estilo, enc_po_base(x.po), x.color)
      from encajado_aud_sistemas s
      cross join lateral (
        select btrim(p.v) as po, btrim(c.v) as color,
               (cardinality(string_to_array(coalesce(s.po,''), ', ')) > 1 or cardinality(string_to_array(coalesce(s.color,''), ', ')) > 1) as multi
          from unnest(case when coalesce(s.po,'') = '' then array[''::text] else string_to_array(s.po, ', ') end) p(v),
               unnest(case when coalesce(s.color,'') = '' then array[''::text] else string_to_array(s.color, ', ') end) c(v)
      ) x
     where coalesce(s.proceso,'') not ilike 'artes%'
       and upper(btrim(coalesce(s.estado,''))) in ('APROBADO','RECHAZADO')
  ), vivas as (
    select m.* from m, corte where not (m.f <> '' and m.f < corte.c)
  ), cruce as (
    select v.*, coalesce(q1.destino, q2.destino) as k
      from vivas v
      left join q q1 on q1.k = v.kk1
      left join q q2 on q2.k = v.kk2 and v.kk2 <> v.kk1
  ), sal as (
    select k, jsonb_agg(jsonb_build_object(
             'f', f, 't', upper(btrim(coalesce(tipo,''))), 'r', upper(btrim(coalesce(resultado,''))),
             'a', btrim(coalesce(auditor,'')), 's', btrim(coalesce(servicio,'')),
             'ie', upper(btrim(coalesce(int_ext,''))),
             'l', coalesce(lote,0), 'm', coalesce(muestra,0))
           order by f desc, id_auditoria) as lista, count(*) as n
      from cruce where k is not null group by k
  )
  select jsonb_build_object(
    'ok', true,
    'claves', coalesce((select jsonb_object_agg(k, lista) from sal), '{}'::jsonb),
    'total', coalesce((select sum(n) from sal), 0),
    'combinaciones', (select count(*) from sal),
    'pedidas', (select count(distinct destino) from q),
    'leidas', (select count(*) from m),
    'omitidas', (select count(*) from m, corte where m.f <> '' and m.f < corte.c),
    'meses', p_meses,
    'fuente', 'supabase')
$f$;

-- =====================================================================================
-- MARCHA ATRÁS (solo si Christian lo pide; no se ejecuta sola)
--   a) Vista: volver a crear encajado_aud_vivo dejando solo la primera mitad
--      (desde «SELECT fila_hoja» hasta «= 'VIGENTE'::text», sin el UNION ALL).
--   b) Función encajado_auditorias_visor: en el bloque «m» dejar solo
--        select p.*, enc_fecha_iso(p.fecha) as f,
--               enc_clave(p.grupo, p.estilo, p.po, p.color) as kk1,
--               enc_clave(p.grupo, p.estilo, enc_po_base(p.po), p.color) as kk2
--          from publico_final p
--   c) Con a) y b) hechos: drop function public.encajado_aud_cargar(jsonb, text);
--      drop table public.encajado_aud_sistemas;   (antes, lista exacta y confirmación)
-- =====================================================================================
