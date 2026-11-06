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

## Control de Cajas (rama `control-cajas`, desde el 06/11/2026; aún no publicado)
Encajado con escáner y peso (pedido de Christian tras una multa). Prefijo `caja_`, puerta `caja_api`, registro `registro_sql/CJ01_control_cajas.sql` (el catálogo de cajas CJ02 no va a GitHub: `AD\entregables\Control_Cajas`).
- `control_cajas.html` — **entrada** (tablero): filtros (packings abiertos/todos, cliente, búsqueda), KPIs (cajas cerradas, por pesar, observadas, % prendas escaneadas), pestañas Packings, Cajas, Códigos de prenda y Cajas vacías, Excel LIVES. **Cargar packing** lee el Excel «Relación de cajas packing list» del sistema (hoja de cajas + hoja de neto/bruto y medidas), verifica las tallas contra el «Total general» y lo guarda. **Escanear** y **Pesar y cerrar** abren las otras pantallas en una ventana. Detalle de caja: Imprimir etiqueta y Reabrir (con motivo). Códigos: corregir (con motivo), marcar revisado, bloquear. Cajas vacías: pesar la caja vacía de cada código.
- `escaneo_cajas.html` — **celular** (también link directo): elige packing y caja, escanea el hang tag (escáner tipo teclado + Enter). Correcta / SOBRA / NO CORRESPONDE con sonido y vibración. Código desconocido: se registra una vez con estilo, color y talla leídos del hang tag y se vuelve a escanear. Quitar prenda.
- `cierre_cajas.html` — **PC de la mesa**: cajas por pesar, código de caja (reconocido por la medida del packing o elegido), peso escrito a mano en kg. Si falta la caja vacía o el peso de una prenda, lo pide una sola vez y sigue con el peso ya escrito. Si no cuadra: segunda lectura; si sigue, OBSERVADA (≈ prendas de más/menos) → pesar otra vez o aprobar con motivo. Cerrada: etiqueta 100×150 mm con código de barras de la caja (JsBarcode). `?etiqueta=CJ-…` solo muestra la etiqueta.
- Peso esperado = caja vacía pesada + Σ peso por prenda escaneada; margen = media prenda más liviana. Balanza de 10 g (prueba del 06/11/2026: caja ATM vacía 1,10 kg; prendas de MM Lafleur ~290 g).
- Quién registra: libre durante las pruebas (`caja_parametros.REGISTRO_LIBRE`). Rodrigo: supervisión. A Sistemas: `caja_puede` es la pieza que reemplazan.
