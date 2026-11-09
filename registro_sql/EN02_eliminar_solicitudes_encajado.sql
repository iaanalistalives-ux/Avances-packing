-- EN02 · Eliminar solicitudes de prendas a Encajados (09/11/2026, pedido de Christian). Solo registro: ya se ejecutó como migración.
-- Respaldo de las 5 filas: AD\datos\encajado_solicitudes\encajado_solicitudes_respaldo_20261109.json (no va a GitHub).
drop function if exists public.encajado_solicitar(text,text,text,text,text,text,text,jsonb,text);
drop function if exists public.encajado_solicitud_estado(text,text,text);
drop function if exists public.encajado_solicitudes_lista(text,integer);
drop table if exists public.encajado_solicitudes;
