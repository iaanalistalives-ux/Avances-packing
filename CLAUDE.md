# CLAUDE.md — Avances de Packing / Encajado (Avances-packing)

Las reglas generales de trabajo están en el repo privado `lives-instrucciones` (CLAUDE.md). Este archivo solo describe esta herramienta.

## Qué hace
Avance de encajado por PO, color y talla, cruzado con las auditorías, y pedidos de prendas a Encajados.
- `index.html` — **visor de las auditoras** "Avance por talla": tarjetas por PO/color/talla con historial de auditorías y estatus del cliente. Desde la tarjeta se **piden prendas a Encajados** (y se anulan las propias pendientes). Excel propio (SheetJS, hoja "Avance Encajado") además del Excel LIVES.
- `dashboard_avances_auditoria.html` — **dashboard** de solo lectura: filtros (cliente, grupo, estilo, PO, color, semana, mes, estado, estatus del cliente, fechas) y pestañas Estatus, Tendencia, Desgloses y Por Cliente. Cada fila abre el visor.
- `estatus_cliente_lives.html` — **formulario de Calidad**: busca por OP (o cliente → grupo → estilo → PO → color) y marca APROBADO_CLIENTE o RECHAZADO_CLIENTE. Ya no se bloquea si la auditoría no está aprobada (decisión temporal de Datos e IA); solo avisa.
- `carga_encajado_lives_conectado.html` — **carga** de los Excel "Avance Encajado" (uno o varios; hoja que contenga "ENCAJADO"; varios cuadros por taller). Muestra una revisión previa por PO y color y guarda en tramos de 25 filas; al volver a subir reemplaza color por color.
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
