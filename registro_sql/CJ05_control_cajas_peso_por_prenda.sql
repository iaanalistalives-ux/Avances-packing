-- CJ05 · Control de Cajas: peso prenda por prenda (pedido de Rodrigo, 13/11/2026)
-- La caja se llena sobre la balanza. Se elige el código de caja (su peso vacía sale del guardado en caja_tipos;
-- no se pesa, salvo que ese código aún no tenga peso) y, después de cada prenda escaneada, se escribe lo que marca la balanza. El sistema resta la lectura anterior: ese es el peso de la prenda.
-- Si no cuadra con el peso conocido de la prenda: segunda lectura; si sigue sin cuadrar, no deja
-- escanear la siguiente hasta retirar la prenda o aprobar con motivo. Con la última prenda la caja se cierra.
-- Interruptor: caja_parametros.PESO_POR_PRENDA (SI / NO). Con NO todo vuelve a ser como antes (peso al final, en la mesa).
-- Exclusivo de Postgres (para Sistemas): jsonb, percentile_cont, el parche de caja_api con pg_get_functiondef.

-- 1) Columnas nuevas en caja_cajas (no se cambia ninguna existente)
alter table caja_cajas
  add column if not exists peso_modo text check (peso_modo in ('PRENDA')),   -- PRENDA = esta caja se pesa prenda por prenda
  add column if not exists tara_real_g numeric,                               -- lo que marcó ESTA caja vacía
  add column if not exists ajuste_esperado_g numeric;                         -- no nulo = se retiró una prenda y falta la lectura de ajuste

-- 2) caja_pesos acepta el origen PRENDA (cada prenda pesada es una muestra de su código)
alter table caja_pesos drop constraint caja_pesos_origen_check;
alter table caja_pesos add constraint caja_pesos_origen_check check (origen in ('MUESTRA','CAJA','PRENDA'));

-- 3) Tabla nueva: una fila por lectura de balanza
create table if not exists caja_lecturas (
  id bigint generated always as identity primary key,
  caja_id text not null references caja_cajas(id),
  tipo text not null check (tipo in ('VACIA','PRENDA','AJUSTE')),
  escaneo_id bigint references caja_escaneos(id),
  linea_id bigint references caja_lineas(id),
  barcode text,
  lectura_g numeric not null check (lectura_g > 0),   -- lo que marca la balanza
  anterior_g numeric,                                  -- lectura válida anterior
  delta_g numeric,                                     -- lectura - anterior = peso de la prenda
  esperado_g numeric,                                  -- peso de referencia (prenda, caja vacía o ajuste)
  tolerancia_g numeric,
  resultado text not null check (resultado in ('OK','REFERENCIA','FUERA','APROBADO_CON_MOTIVO')),
  valida boolean not null default true,                -- false = primera lectura que no cuadró, o prenda retirada
  quitada boolean not null default false,              -- true = la prenda se retiró después de pesarla
  motivo text,
  token text unique,
  usuario text,
  fecha timestamptz not null default now()
);
create index if not exists caja_lecturas_caja_idx on caja_lecturas(caja_id, id);
create index if not exists caja_lecturas_escaneo_idx on caja_lecturas(escaneo_id);
alter table caja_lecturas enable row level security;
revoke all on caja_lecturas from anon, authenticated;   -- solo se entra por caja_api

-- 4) Parámetros
insert into caja_parametros(clave,valor,descripcion)
select v.clave, v.valor, v.descripcion from (values
  ('PESO_POR_PRENDA','SI','SI = la caja se llena sobre la balanza y se escribe el peso después de cada prenda; NO = peso al final en la mesa'),
  ('BALANZA_PASO_G','10','Gramos de cada paso de la balanza; el margen mínimo de una lectura es el doble')
) v(clave,valor,descripcion)
where not exists (select 1 from caja_parametros p where p.clave = v.clave);

-- 5) Funciones de apoyo
create or replace function caja_kg_(g numeric) returns text language sql immutable as $$
  select replace(to_char(round(g/1000.0,2),'FM9990.00'),'.',',')
$$;

create or replace function caja_modo_prenda_(p_caja text) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select coalesce(c.peso_modo = 'PRENDA', false)
      or (coalesce(caja_par('PESO_POR_PRENDA'),'NO') = 'SI' and c.estado in ('PENDIENTE','EN_PROCESO')
          and not exists (select 1 from caja_escaneos e where e.caja_id = c.id and e.resultado = 'OK' and not e.anulado))
  from caja_cajas c where c.id = p_caja
$$;

-- Qué lectura falta en la caja: VACIA, AJUSTE, PRENDA o nada
create or replace function caja_lectura_pendiente_(p_caja text) returns jsonb
language plpgsql stable security definer set search_path to 'public' as $$
declare c caja_cajas%rowtype; v_modo boolean; v_vacia numeric; v_ult numeric; e record; v_ref numeric; x jsonb;
begin
  select * into c from caja_cajas where id = p_caja;
  if c.id is null then return jsonb_build_object('modo',false,'pendiente',null); end if;
  v_modo := coalesce(caja_modo_prenda_(p_caja), false);
  select lectura_g into v_vacia from caja_lecturas where caja_id = p_caja and tipo = 'VACIA' and valida order by id desc limit 1;
  select lectura_g into v_ult from caja_lecturas where caja_id = p_caja and valida order by id desc limit 1;
  x := jsonb_build_object('modo', v_modo, 'pendiente', null, 'vacia_g', v_vacia, 'ultima_g', v_ult);
  if not v_modo or c.estado not in ('PENDIENTE','EN_PROCESO') then return x; end if;
  if v_vacia is null then
    select coalesce(t.tara_g, t.tara_hoja_g, nullif(t.tara_sistema_g,0)) into v_ref from caja_tipos t where t.codigo = c.tipo_cod;
    return x || jsonb_build_object('pendiente','VACIA','referencia_g', v_ref, 'tipo_cod', c.tipo_cod);
  end if;
  if c.ajuste_esperado_g is not null then
    return x || jsonb_build_object('pendiente','AJUSTE','referencia_g', c.ajuste_esperado_g);
  end if;
  select s.id, s.barcode, s.estilo, s.color_cod, s.talla, s.linea_id into e from caja_escaneos s
   where s.caja_id = p_caja and s.resultado = 'OK' and not s.anulado
     and not exists (select 1 from caja_lecturas l where l.escaneo_id = s.id and l.tipo = 'PRENDA' and l.valida)
   order by s.id limit 1;
  if e.id is null then return x; end if;
  select coalesce(k.peso_unit_g, caja_peso_ref_(k.barcode)) into v_ref from caja_codigos k where k.barcode = e.barcode;
  return x || jsonb_build_object('pendiente','PRENDA','escaneo_id', e.id, 'barcode', e.barcode, 'estilo', e.estilo,
    'color_cod', e.color_cod, 'talla', e.talla, 'referencia_g', v_ref,
    'color_nombre', (select l.color_nombre from caja_lineas l where l.id = e.linea_id),
    'reconfirmar', exists(select 1 from caja_lecturas l where l.escaneo_id = e.id and l.resultado = 'FUERA'));
end $$;

-- Al quitar una prenda ya pesada: su lectura deja de valer y la caja pide una lectura de ajuste
create or replace function caja_lectura_quitar_(p_escaneo bigint) returns void
language plpgsql security definer set search_path to 'public' as $$
declare l caja_lecturas%rowtype; v_ult numeric;
begin
  select * into l from caja_lecturas where escaneo_id = p_escaneo and tipo = 'PRENDA' and valida order by id desc limit 1;
  if l.id is not null then
    select lectura_g into v_ult from caja_lecturas where caja_id = l.caja_id and valida order by id desc limit 1;
    update caja_cajas set ajuste_esperado_g = coalesce(ajuste_esperado_g, v_ult) - l.delta_g where id = l.caja_id;
  end if;
  update caja_lecturas set valida = false, quitada = true where escaneo_id = p_escaneo and valida;
end $$;

-- Registrar una lectura de balanza (acción «lectura» de caja_api)
create or replace function caja_lectura_(p jsonb, v_usuario text) returns jsonb
language plpgsql security definer set search_path to 'public' as $$
declare c caja_cajas%rowtype; x jsonb; v_pen text; v_peso numeric; v_ant numeric; v_ref numeric; v_tol numeric; v_delta numeric;
  v_conf boolean := coalesce((p->>'confirmado')::boolean, false); v_mot text := nullif(btrim(coalesce(p->>'motivo','')),'');
  v_paso numeric := coalesce(nullif(caja_par('BALANZA_PASO_G'),'')::numeric, 10);
  v_pct numeric := coalesce(nullif(caja_par('TARA_RANGO_PCT'),'')::numeric, 15);
  v_res text; v_esc bigint; v_bc text; v_lin bigint; v_req int; v_ok int; v_cerrada boolean := false; v_n int; v_tipo text;
begin
  select * into c from caja_cajas where id = p->>'caja_id' for update;
  if c.id is null then return jsonb_build_object('ok',false,'error','No existe la caja'); end if;
  if coalesce(p->>'token','') <> '' and exists(select 1 from caja_lecturas where token = p->>'token') then
    return jsonb_build_object('ok',true,'repetido',true) || caja_detalle_(c.id);
  end if;
  v_peso := nullif(p->>'peso_g','')::numeric;
  x := caja_lectura_pendiente_(c.id); v_pen := x->>'pendiente';
  if v_pen is null then
    return jsonb_build_object('ok',false,'error','No hay nada que pesar en esta caja: escanea la siguiente prenda') || caja_detalle_(c.id);
  end if;
  if v_pen <> 'VACIA' and (coalesce(v_peso,0) <= 0 or v_peso > 60000) then return jsonb_build_object('ok',false,'error','Peso no válido'); end if;
  v_ant := (x->>'ultima_g')::numeric; v_ref := (x->>'referencia_g')::numeric;

  if v_pen = 'VACIA' then
    -- La caja vacía NO se pesa (pedido de Christian, 13/11/2026): se elige el código de caja y su peso sale del guardado
    v_tipo := coalesce(nullif(upper(btrim(coalesce(p->>'tipo_cod',''))),''), c.tipo_cod);
    if v_tipo is null or not exists(select 1 from caja_tipos where codigo = v_tipo) then
      return jsonb_build_object('ok',false,'falta_tipo',true,'error','Elige el código de la caja') || caja_detalle_(c.id);
    end if;
    select coalesce(t.tara_g, t.tara_hoja_g, nullif(t.tara_sistema_g,0)) into v_ref from caja_tipos t where t.codigo = v_tipo;
    if v_ref is null then
      return jsonb_build_object('ok',false,'falta_tara',true,'tipo_cod',v_tipo,'error','La caja '||v_tipo||' aún no tiene peso guardado: pésala vacía una vez y escribe lo que marca') || caja_detalle_(c.id);
    end if;
    v_res := 'OK'; v_peso := v_ref;
    insert into caja_lecturas(caja_id,tipo,lectura_g,esperado_g,resultado,token,usuario)
    values (c.id,'VACIA',v_ref,v_ref,v_res,nullif(p->>'token',''),v_usuario);
    update caja_cajas set tipo_cod = v_tipo, peso_modo = 'PRENDA', tara_real_g = v_ref, actualizado = now() where id = c.id;
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (c.packing_id,c.id,'LECTURA_VACIA',
      jsonb_build_object('tipo_cod',v_tipo,'peso_g',v_ref,'origen','CATALOGO'),v_usuario);

  elsif v_pen = 'AJUSTE' then
    v_tol := 2 * v_paso;
    if abs(v_peso - v_ref) <= v_tol then v_res := 'OK';
    elsif not v_conf then
      insert into caja_lecturas(caja_id,tipo,lectura_g,anterior_g,esperado_g,tolerancia_g,resultado,valida,usuario)
      values (c.id,'AJUSTE',v_peso,v_ant,v_ref,v_tol,'FUERA',false,v_usuario);
      return jsonb_build_object('ok',false,'reconfirmar',true,'error','Después de retirar la prenda la balanza debería marcar cerca de '||caja_kg_(v_ref)||' kg y escribiste '||caja_kg_(v_peso)||' kg. Revisa la caja y escribe el peso otra vez.') || caja_detalle_(c.id);
    elsif length(coalesce(v_mot,'')) < 10 then
      return jsonb_build_object('ok',false,'fuera',true,'error','Sigue sin cuadrar (debería marcar cerca de '||caja_kg_(v_ref)||' kg). Escribe el motivo (al menos 10 letras) para seguir.') || caja_detalle_(c.id);
    else v_res := 'APROBADO_CON_MOTIVO';
    end if;
    insert into caja_lecturas(caja_id,tipo,lectura_g,anterior_g,esperado_g,tolerancia_g,resultado,motivo,token,usuario)
    values (c.id,'AJUSTE',v_peso,v_ant,v_ref,v_tol,v_res,v_mot,nullif(p->>'token',''),v_usuario);
    update caja_cajas set ajuste_esperado_g = null, actualizado = now() where id = c.id;
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (c.packing_id,c.id,'LECTURA_AJUSTE',
      jsonb_build_object('peso_g',v_peso,'esperado_g',v_ref,'resultado',v_res,'motivo',v_mot),v_usuario);

  else  -- PRENDA
    v_esc := (x->>'escaneo_id')::bigint; v_bc := x->>'barcode';
    select linea_id into v_lin from caja_escaneos where id = v_esc;
    v_delta := v_peso - v_ant;
    if v_delta <= 0 then
      return jsonb_build_object('ok',false,'error','Antes de esta prenda la balanza marcaba '||caja_kg_(v_ant)||' kg y escribiste '||caja_kg_(v_peso)||' kg. Pon la prenda en la caja y escribe lo que marca ahora.') || caja_detalle_(c.id);
    end if;
    v_tol := greatest(coalesce(v_ref,0) * v_pct / 100, 2 * v_paso);
    if v_ref is null then v_res := 'REFERENCIA';
    elsif abs(v_delta - v_ref) <= v_tol then v_res := 'OK';
    elsif not v_conf then
      insert into caja_lecturas(caja_id,tipo,escaneo_id,linea_id,barcode,lectura_g,anterior_g,delta_g,esperado_g,tolerancia_g,resultado,valida,usuario)
      values (c.id,'PRENDA',v_esc,v_lin,v_bc,v_peso,v_ant,v_delta,v_ref,v_tol,'FUERA',false,v_usuario);
      return jsonb_build_object('ok',false,'reconfirmar',true,'delta_g',v_delta,'esperado_g',v_ref,
        'error','Esta prenda pesó '||round(v_delta)||' g y se esperaba cerca de '||round(v_ref)||' g. Revisa que entró una sola prenda y escribe otra vez lo que marca la balanza.') || caja_detalle_(c.id);
    elsif length(coalesce(v_mot,'')) < 10 then
      return jsonb_build_object('ok',false,'fuera',true,'delta_g',v_delta,'esperado_g',v_ref,'tolerancia_g',v_tol,
        'error','Sigue sin cuadrar: pesó '||round(v_delta)||' g y se esperaba cerca de '||round(v_ref)||' g (margen ±'||round(v_tol)||' g). Retira la prenda y revisa, o aprueba con motivo (al menos 10 letras).') || caja_detalle_(c.id);
    else v_res := 'APROBADO_CON_MOTIVO';
    end if;
    insert into caja_lecturas(caja_id,tipo,escaneo_id,linea_id,barcode,lectura_g,anterior_g,delta_g,esperado_g,tolerancia_g,resultado,motivo,token,usuario)
    values (c.id,'PRENDA',v_esc,v_lin,v_bc,v_peso,v_ant,v_delta,v_ref,v_tol,v_res,v_mot,nullif(p->>'token',''),v_usuario);
    insert into caja_pesos(barcode,cantidad,peso_g,origen,caja_id,usuario,fuera_rango,motivo)
    values (v_bc, 1, v_delta, 'PRENDA', c.id, v_usuario, v_res = 'APROBADO_CON_MOTIVO', v_mot);
    perform caja_recalc_peso(v_bc);
    if v_res = 'APROBADO_CON_MOTIVO' then
      insert into caja_eventos(packing_id,caja_id,barcode,accion,detalle,usuario) values (c.packing_id,c.id,v_bc,'PRENDA_APROBADA_CON_MOTIVO',
        jsonb_build_object('peso_g',v_delta,'esperado_g',v_ref,'tolerancia_g',v_tol,'motivo',v_mot),v_usuario);
    end if;
    -- ¿ya están todas las prendas escaneadas y pesadas? entonces la caja se cierra con esta lectura
    select coalesce(sum(l.cantidad),0), coalesce(sum((select count(*) from caja_escaneos e where e.linea_id=l.id and e.resultado='OK' and not e.anulado)),0)
      into v_req, v_ok from caja_lineas l where l.caja_id = c.id;
    if v_ok >= v_req and v_req > 0 and (caja_lectura_pendiente_(c.id)->>'pendiente') is null then
      select count(*) into v_n from caja_lecturas where caja_id = c.id and valida and resultado = 'APROBADO_CON_MOTIVO';
      update caja_cajas set
        peso_bruto_g = v_peso,
        peso_esperado_g = round(tara_real_g + (select sum(coalesce(esperado_g, delta_g)) from caja_lecturas where caja_id = c.id and tipo = 'PRENDA' and valida), 1),
        tolerancia_g = null,
        peso_resultado = case when v_n > 0 then 'APROBADO_CON_MOTIVO' else 'OK' end,
        peso_origen = 'DIGITADO',
        peso_motivo = case when v_n > 0 then 'Peso prenda por prenda: '||v_n||' lectura(s) aprobada(s) con motivo' end,
        estado = 'CERRADA', escaneada_en = coalesce(escaneada_en, now()), cerrada_en = now(), cerrada_por = v_usuario, actualizado = now()
      where id = c.id;
      insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (c.packing_id,c.id,'PESO',
        jsonb_build_object('peso_g',v_peso,'modo','PRENDA','prendas',v_ok,'aprobadas_con_motivo',v_n),v_usuario);
      v_cerrada := true;
    end if;
  end if;
  return jsonb_build_object('ok',true,'tipo',v_pen,'resultado',v_res,'delta_g',v_delta,'cerrada',v_cerrada) || caja_detalle_(c.id);
end $$;

-- Reportes: peso por línea del packing (estilo + color + talla de cada caja) y prenda por prenda
create or replace function caja_pesos_linea_() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(q order by q.packing, q.numero, q.estilo, q.color, q.talla), '[]') from (
    select k.id packing_id, k.packing, k.cliente, k.po, c.numero, l.estilo, coalesce(l.color_nombre,l.color_cod) color, l.talla, l.op, l.cantidad,
           count(*) pesadas, sum(r.delta_g) total_g, round(sum(r.delta_g)/count(*),1) promedio_g, min(r.delta_g) min_g, max(r.delta_g) max_g
      from caja_lecturas r join caja_lineas l on l.id = r.linea_id join caja_cajas c on c.id = r.caja_id join caja_packings k on k.id = c.packing_id
     where r.tipo = 'PRENDA' and r.valida and k.estado <> 'ANULADO' and c.estado <> 'ANULADA'
     group by k.id, k.packing, k.cliente, k.po, c.numero, l.id, l.estilo, l.color_nombre, l.color_cod, l.talla, l.op, l.cantidad) q
$$;

create or replace function caja_pesos_prenda_() returns jsonb
language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_agg(q order by q.packing, q.numero, q.orden), '[]') from (
    select k.id packing_id, k.packing, k.cliente, k.po, c.numero, row_number() over (partition by c.id order by r.id) orden,
           l.estilo, coalesce(l.color_nombre,l.color_cod) color, l.talla, l.op, r.barcode, r.delta_g, r.esperado_g, r.lectura_g,
           r.resultado, r.motivo, caja_nombre_(r.usuario) nombre, r.fecha
      from caja_lecturas r join caja_lineas l on l.id = r.linea_id join caja_cajas c on c.id = r.caja_id join caja_packings k on k.id = c.packing_id
     where r.tipo = 'PRENDA' and r.valida and k.estado <> 'ANULADO' and c.estado <> 'ANULADA') q
$$;

revoke execute on function caja_lectura_(jsonb,text), caja_lectura_quitar_(bigint) from public, anon, authenticated;

-- 6) caja_detalle_: agrega qué lectura falta, el peso por línea y el peso de cada escaneo
create or replace function caja_detalle_(p_caja text) returns jsonb
language sql stable security definer set search_path to 'public' as $function$
  select jsonb_build_object(
    'caja', to_jsonb(c) || jsonb_build_object(
        'packing', k.packing, 'cliente', k.cliente, 'destino', k.destino, 'grupo', k.grupo, 'po', k.po,
        'total_cajas', (select count(*) from caja_cajas z where z.packing_id = c.packing_id and z.estado <> 'ANULADA'),
        'tipo_medidas', t.descripcion, 'tara_g', coalesce(c.tara_real_g, t.tara_g), 'tara_sistema_g', t.tara_sistema_g, 'tara_hoja_g', t.tara_hoja_g,
        'cerrada_nombre', caja_nombre_(c.cerrada_por)),
    'peso', caja_lectura_pendiente_(c.id),
    'lineas', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'estilo', l.estilo, 'lote', l.lote, 'color_cod', l.color_cod, 'color_nombre', l.color_nombre,
        'talla', l.talla, 'cantidad', l.cantidad, 'op', l.op, 'estilo_lives', l.estilo_lives,
        'escaneadas', (select count(*) from caja_escaneos e where e.linea_id = l.id and e.resultado = 'OK' and not e.anulado),
        'pesadas', (select count(*) from caja_lecturas r where r.linea_id = l.id and r.tipo = 'PRENDA' and r.valida),
        'peso_g', (select sum(r.delta_g) from caja_lecturas r where r.linea_id = l.id and r.tipo = 'PRENDA' and r.valida),
        'peso_min_g', (select min(r.delta_g) from caja_lecturas r where r.linea_id = l.id and r.tipo = 'PRENDA' and r.valida),
        'peso_max_g', (select max(r.delta_g) from caja_lecturas r where r.linea_id = l.id and r.tipo = 'PRENDA' and r.valida))
        order by l.estilo, l.color_cod, l.id) from caja_lineas l where l.caja_id = c.id), '[]'),
    'escaneos', coalesce((select jsonb_agg(x order by x->>'fecha' desc) from (
        select jsonb_build_object('id', e.id, 'barcode', e.barcode, 'resultado', e.resultado, 'estilo', e.estilo,
               'color_cod', e.color_cod, 'talla', e.talla, 'fecha', e.fecha, 'anulado', e.anulado,
               'nombre', caja_nombre_(e.usuario),
               'peso_g', (select r.delta_g from caja_lecturas r where r.escaneo_id = e.id and r.tipo = 'PRENDA' and r.valida order by r.id desc limit 1),
               'peso_res', (select r.resultado from caja_lecturas r where r.escaneo_id = e.id and r.tipo = 'PRENDA' and r.valida order by r.id desc limit 1)) x
          from caja_escaneos e where e.caja_id = c.id order by e.id desc limit 40) q), '[]'))
  from caja_cajas c join caja_packings k on k.id = c.packing_id
  left join caja_tipos t on t.codigo = c.tipo_cod
  where c.id = p_caja
$function$;

-- 7) Parche de caja_api (la puerta): 7 cambios puntuales sobre la función tal como está hoy.
--    Cada cambio exige encontrar su texto exactamente una vez; si no, no se aplica nada.
do $do$
declare d text := pg_get_functiondef('public.caja_api(text,jsonb)'::regprocedure); a text; b text; i int;
  cambios text[][] := array[
    -- 1. «lectura» es una acción que escribe
    [$a$'guardar_tipo','guardar_parametro','revisar_tara');$a$,
     $b$'guardar_tipo','guardar_parametro','revisar_tara','lectura');$b$],
    -- 2. escanear: no deja pasar a la siguiente prenda si falta una lectura de balanza
    [$a$if v_caja.estado = 'ANULADA' then return jsonb_build_object('ok',false,'error','La caja está anulada'); end if;$a$,
     $b$if v_caja.estado = 'ANULADA' then return jsonb_build_object('ok',false,'error','La caja está anulada'); end if;
    x := caja_lectura_pendiente_(v_caja.id);
    if x->>'pendiente' is not null then
      return jsonb_build_object('ok',false,'falta_lectura',true,'error', case x->>'pendiente'
        when 'VACIA' then 'Antes de la primera prenda, elige el código de la caja'
        when 'AJUSTE' then 'Se retiró una prenda: escribe lo que marca la balanza ahora antes de seguir'
        else 'Falta escribir el peso de la prenda anterior' end) || caja_detalle_(v_caja.id);
    end if;$b$],
    -- 3. escanear: la caja pesada prenda por prenda no pasa a «Por pesar»; la cierra su última lectura
    [$a$case when estado='OBSERVADA' then 'OBSERVADA' else 'ESCANEADA' end$a$,
     $b$case when estado='OBSERVADA' then 'OBSERVADA' when peso_modo='PRENDA' then 'EN_PROCESO' else 'ESCANEADA' end$b$],
    -- 4. quitar: la lectura de esa prenda deja de valer y se pide lectura de ajuste
    [$a$insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'QUITA_PRENDA'$a$,
     $b$perform caja_lectura_quitar_((p->>'escaneo_id')::bigint);
    insert into caja_eventos(packing_id,caja_id,accion,detalle,usuario) values (v_caja.packing_id,v_caja.id,'QUITA_PRENDA'$b$],
    -- 5. acción nueva «lectura»
    [$a$elsif p_accion = 'guardar_tipo' then$a$,
     $b$elsif p_accion = 'lectura' then
    return caja_lectura_(p, v_usuario);
  elsif p_accion = 'guardar_tipo' then$b$],
    -- 6. tablero: trae el peso por línea y prenda por prenda (para la pantalla y el Excel)
    [$a$'taras', caja_taras_lista_(),$a$,
     $b$'pesos_linea', caja_pesos_linea_(), 'pesos_prenda', caja_pesos_prenda_(),
      'taras', caja_taras_lista_(),$b$],
    -- 7. tablero: el neto usa el peso real de la caja vacía cuando se pesó
    [$a$sum(c.peso_bruto_g - coalesce(t.tara_g,0))$a$,
     $b$sum(c.peso_bruto_g - coalesce(c.tara_real_g,t.tara_g,0))$b$]
  ];
begin
  for i in 1 .. array_length(cambios,1) loop
    a := cambios[i][1]; b := cambios[i][2];
    if (length(d) - length(replace(d, a, ''))) / length(a) <> 1 then
      raise exception 'CJ05: el cambio % de caja_api no encontró su texto exactamente una vez', i;
    end if;
    d := replace(d, a, b);
  end loop;
  execute d;
end $do$;

-- Marcha atrás rápida (sin borrar nada): update caja_parametros set valor='NO' where clave='PESO_POR_PRENDA';
