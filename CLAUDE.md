# CLAUDE.md — Avances de Packing / Encajado (Avances-packing)

Las reglas generales de trabajo están en el repo privado `lives-instrucciones` (CLAUDE.md). Este archivo solo describe esta herramienta.

## Qué hace
Avance de encajado por PO, color y talla, cruzado con las auditorías, y pedidos de prendas a Encajados.
- `index.html` — **visor de las auditoras** "Avance por talla": tarjetas por PO/color/talla con historial de auditorías y estatus del cliente. Desde la tarjeta se **piden prendas a Encajados** (y se anulan las propias pendientes). Excel propio (SheetJS, hoja "Avance Encajado") además del Excel LIVES.
- `dashboard_avances_auditoria.html` — **dashboard** de solo lectura: filtros (cliente, grupo, estilo, PO, color, semana, mes, estado, estatus del cliente, fechas) y pestañas Estatus, Tendencia, Desgloses y Por Cliente. Cada fila abre el visor.
- `estatus_cliente_lives.html` — **formulario de Calidad**: busca por OP (o cliente → grupo → estilo → PO → color) y marca APROBADO_CLIENTE o RECHAZADO_CLIENTE. Ya no se bloquea si la auditoría no está aprobada (decisión temporal de Datos e IA); solo avisa.
- `carga_encajado_lives_conectado.html` — **carga** de los Excel "Avance Encajado" (uno o varios; hoja que contenga "ENCAJADO"; varios cuadros por taller). Muestra una revisión previa por PO y color y guarda en tramos de 25 filas; al volver a subir reemplaza color por color y OP por OP (el color se compara por su descripción; otra OP de la misma PO y color no se toca; los avances que quedan sin detalle, sin estatus del cliente, se quitan).
- `solicitudes_encajado_lives.html` — **bandeja de Encajados**: pedidos de las auditoras (Pendientes / Entregadas / Todas, últimos 120 días), agrupados por PO y color, con "Marcar entregada". Se recarga sola cada 60 s.
- Ninguna pantalla habla ya con Google: la dirección vieja del Apps Script solo queda en el código como interruptor o sin uso.

## Base de datos (Supabase lives-datos)
- Vistas: `publico_encajado_detalle` (visor, de `encajado_detalle`), `publico_encajado_dashboard` (dashboard, de `encajado_avances` y `auditorias`), `publico_encajado_avances` (estatus, de `encajado_avances`).
- Leer: `encajado_auditorias_visor`, `encajado_estatus`, `encajado_auditorias_de`, `encajado_solicitudes_lista`, `encajado_resumen_po`, `encajado_previsualizar`.
- Registrar:
  - Carga: `encajado_guardar_lote` (tablas `encajado_avances`, `encajado_detalle`, `encajado_cargas`, `encajado_lotes`, `encajado_historial`).
  - Estatus del cliente: `encajado_marcar_cliente` (`encajado_avances`, `encajado_historial`).
  - Pedidos de prendas: `encajado_solicitar` y `encajado_solicitud_estado` (`encajado_solicitudes`).
- No usa Storage.

## Quién la usa
Según las entradas por el portal de los últimos 30 días al 21/10/2026: 8 personas (digitadoras de Acabados y de Calidad Manufactura, supervisores de planta y de calidad, gerencia).

## Quién puede registrar
- Registra quien entra con su usuario del portal: el nombre de quien carga, marca o pide sale de la sesión. Sin sesión, el visor no deja pedir prendas ("Abre el visor desde el portal para solicitar").
- Cada auditora anula solo sus propios pedidos pendientes.
- A Sistemas: aquí va su control de roles (ver o registrar) para cargar, marcar estatus y atender pedidos.

## Pendientes vistos al escribir esto (21/10/2026)
- `index.html` enlaza a `carga_encajado_lives_v7.html`, que ya no existe; el cargador actual es `carga_encajado_lives_conectado.html`.
- Textos de ayuda y comentarios viejos que dicen que los datos salen de un Google Sheet.

## Control de Cajas (desde el 06/11/2026)
Encajado con escáner y peso (pedido de Christian tras una multa). Prefijo `caja_`, puerta `caja_api`. Registros: `registro_sql/CJ01_control_cajas.sql` (base), CJ02 (catálogo de cajas de Sistemas: no va a GitHub, está en `AD\entregables\Control_Cajas`), `CJ03_control_cajas_taras.sql` (pesos controlados), `CJ04_control_cajas_contexto.sql` (OP y contexto de códigos y pesos, grabar y contar en un escaneo, peso de referencia por estilo).
Diseño tipo software (06/11/2026): un solo link de entrada; sin panel lateral (el portal ya tiene su menú).
- `control_cajas.html` — **entrada** (va en el portal). Barra: vistas Cajas / Códigos / Cajas vacías, búsqueda, estado del packing; botones **Escanear** y **Pesar y cerrar** (abren las otras pantallas en una ventana encima), Descargar Excel, **Cargar packing** (Excel «Relación de cajas packing list»: valida tallas contra el «Total general»). Cajas: contadores con ícono, tarjetas de packing con anillo de avance, grilla de cajas por color de estado y detalle de la caja (tallas en barras; etiqueta, pesar, escanear, reabrir). Códigos: tarjetas por código (corregir con motivo, revisado, bloquear). Cajas vacías: peso pesado (mediana) vs hoja vs sistema, Pesar vacía, Agregar caja (se elige el código del catálogo de Sistemas con lista; descripción y medidas se llenan solas y solo se escribe el peso; si el código no existe, «Registrar con este código» lo deja «por confirmar»; «La caja no tiene código» le pone uno provisional PC-AAMMDDhhmmss, también «por confirmar», para que Sistemas asigne el oficial) y Pesadas por revisar (aprobar/rechazar). Excel con hoja «Cajas vacías: pesado vs sistema» para Sistemas.
- `escaneo_cajas.html` — **celular o PC** (link directo también): elige packing (tarjetas) y caja (cuadros de color); anillo grande, fichas por talla, destello a pantalla completa (verde correcta, rojo sobra/no corresponde con «Ya la retiré», ámbar código nuevo). Dos formas de escanear, las dos a la vez: lector conectado al celular o PC (USB con adaptador OTG, o Bluetooth; modo teclado + Enter) y botón 📷 con la cámara en modo continuo (Android con Chrome, BarcodeDetector): la cámara queda abierta, cada prenda cuenta sola; prendas iguales (mismo código) cuentan de nuevo solo cuando la cámara dejó de ver el código; un error rojo pausa la cámara hasta «Ya la retiré»; código nuevo o caja completa cierran la cámara (tras grabar el código se reabre sola). No funciona con la cámara en iPhone (no tiene BarcodeDetector). Código nuevo: se graba una vez leyendo el hang tag.
- `cierre_cajas.html` — **PC de la mesa**: pasos 1-4, lista de cajas por pesar, campo tipo pantalla de balanza (peso escrito a mano en kg), pide caja vacía y pesos de prenda una sola vez, segunda lectura si no cuadra, medidor de aguja con franja verde, observada → pesar otra vez o aprobar con motivo; etiqueta 100×150 mm con código de barras (JsBarcode). `?caja=` abre una caja, `?etiqueta=` solo la etiqueta.
- Pesos (CJ03): cada pesada de caja vacía se guarda en `caja_taras`; se usa la mediana de las últimas 3 OK/APROBADA. Si se aleja más de `TARA_RANGO_PCT` (15 %) de la referencia, pide pesar otra vez + motivo y queda POR_REVISAR (no cuenta mientras haya pesadas normales). Peso de prenda: mismo rango, mediana de las últimas 5 muestras. `TARA_APROBACION` = NO durante las pruebas (SI = toda pesada nueva espera aprobación).
- Peso esperado = caja vacía + Σ peso por prenda escaneada; margen = media prenda más liviana. Balanza de 10 g (prueba 06/11/2026: caja ATM vacía 1,10 kg; prendas de MM Lafleur ~290 g).
- Quién registra: libre durante las pruebas (`caja_parametros.REGISTRO_LIBRE`). Rodrigo: supervisión. A Sistemas: `caja_puede` es la pieza que reemplazan.
- Contexto (CJ04): al cargar el packing, cada línea toma su OP y estilo LIVES de `ops` (grupo + estilo cliente + color + PO, trigger `caja_lineas_op`). Cada código guarda cliente, grupo, PO, OP, estilo LIVES, lote, packing y caja donde se grabó; cada pesada guarda packing, caja, OP y cliente (trigger `caja_pesos_ctx`). En Escaneo se toca la ficha de una talla: los códigos nuevos se graban solos con esa talla/color/estilo y cuentan en el mismo escaneo (`escanear` con `auto`); la selección se borra sola al completar la talla. Un código sin peso propio usa de referencia la mediana de otros códigos del mismo estilo+color+talla (o estilo+talla), `caja_peso_ref_`.
