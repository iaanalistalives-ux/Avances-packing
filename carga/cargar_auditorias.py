# -*- coding: utf-8 -*-
r"""Carga de auditorias del aplicativo de Sistemas para Avances de Packing («sube auditorias»).

Uso (solo en la PC, lo corre Claude):
    python cargar_auditorias.py "<Descargas>/Buscar_auditorias_....xlsx" [salida.json]

Que hace:
  1. Lee la hoja «Detalle» del Excel «Buscar auditorias» (ID, Fecha, OP, Proceso, Cliente, Grupo, Estilo,
     PO, Color, Lote AQL, Muestra, Defectos, Taller, Auditor, Estado, Reprocesa a).
  2. Se queda con las auditorias desde el corte (ID de Sistemas 000000005748 = 10/11/2026). Las anteriores
     ya estan en la tabla `auditorias` con su lote real y NO se tocan.
  3. Compara contra la tabla `encajado_aud_sistemas` (solo lee) y dice cuantas son nuevas, cuantas cambian
     y cuantas estan iguales. Lo que no viene en el archivo se MANTIENE: nunca se borra nada.
  4. Deja las filas nuevas o cambiadas en un .json. Este programa NO escribe en la base: la carga la hace
     Claude desde su conexion con  select encajado_aud_cargar('<filas>'::jsonb, '<archivo>')  despues del
     «procede» de Christian, y luego vuelve a correr este programa para comprobar que todo quedo igual.

Reglas (17/11/2026): el proceso «Artes» se guarda pero no cuenta para el estatus; una auditoria con varios
PO o colores da estatus a cada combinacion y su lote no se reparte. Eso lo resuelve la vista
`encajado_aud_vivo`, no este programa.
"""
import sys, os, io, json, warnings, urllib.request

SB = 'https://xxfufpddgoyhbotjmaiy.supabase.co'
KEY = 'sb_publishable_1g-n6UT70EUlNAo8Lyc04w_jKR4LpXZ'
CORTE = '000000005748'
COLS = ['ID', 'Fecha', 'OP', 'Proceso', 'Cliente', 'Grupo', 'Estilo', 'PO', 'Color', 'Lote AQL', 'Muestra',
        'Defectos', 'Taller', 'Auditor', 'Estado', 'Reprocesa a']
CAMPOS = ['id_sistemas', 'fecha', 'op', 'proceso', 'cliente', 'grupo', 'estilo', 'po', 'color', 'lote',
          'muestra', 'defectos', 'taller', 'auditor', 'estado', 'reprocesa_a']


def T(v):
    return '' if v is None else str(v).strip()


def leer(ruta):
    import openpyxl
    warnings.simplefilter('ignore')
    # La hoja se llamaba «Detalle» y desde el 18/11/2026 «Cabecera»: se busca por sus columnas, no por el nombre.
    wb = openpyxl.load_workbook(ruta, data_only=True)
    filas = cab = enc = None
    vistas = []
    for ws in wb.worksheets:
        fs = list(ws.iter_rows(min_row=1, max_row=12, values_only=True))
        c = next((i for i, f in enumerate(fs) if f and T(f[0]).upper() == 'ID'), None)
        if c is None:
            continue
        e = [T(x) for x in fs[c]]
        falta = [x for x in COLS if x not in e]
        vistas.append('%s (faltan: %s)' % (ws.title, ', '.join(falta) or 'ninguna'))
        if not falta:
            if filas is not None:
                raise SystemExit('Hay mas de una hoja con las columnas de auditorias. No se carga.')
            filas, cab, enc = list(ws.iter_rows(values_only=True)), c, e
    if filas is None:
        raise SystemExit('Ninguna hoja trae todas las columnas (ID, Fecha, ..., Lote AQL, Muestra, Defectos). '
                         'Hojas revisadas: ' + '; '.join(vistas) + '. No se carga.')
    pos = [enc.index(c) for c in COLS]
    out = []
    for f in filas[cab + 1:]:
        if not f or not T(f[pos[0]]).isdigit():
            continue
        v = [f[p] for p in pos]
        d, m, a = T(v[1])[:10].split('/')
        out.append([T(v[0]).zfill(12), '%s-%s-%s' % (a, m, d)] + [T(x) for x in v[2:9]] +
                   [float(v[9] or 0), float(v[10] or 0), float(v[11] or 0)] + [T(x) for x in v[12:16]])
    ids = [r[0] for r in out]
    if len(ids) != len(set(ids)):
        raise SystemExit('El Excel trae ID repetidos. No se carga.')
    return out


def en_base():
    out, desde = {}, 0
    while True:
        req = urllib.request.Request(SB + '/rest/v1/encajado_aud_sistemas?select=*&order=id_sistemas&limit=1000&offset=%d' % desde,
                                     headers={'apikey': KEY, 'Authorization': 'Bearer ' + KEY})
        d = json.load(urllib.request.urlopen(req, timeout=120))
        for r in d:
            out[r['id_sistemas']] = r
        desde += 1000
        if len(d) < 1000:
            return out


def igual(fila, t):
    for i, c in enumerate(CAMPOS[1:], 1):
        if c in ('lote', 'muestra', 'defectos'):
            if float(t[c] or 0) != float(fila[i]):
                return False
        elif (t[c] or '') != fila[i]:
            return False
    return True


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    ruta = sys.argv[1]
    F = leer(ruta)
    val = [r for r in F if r[0] >= CORTE]
    B = en_base()
    nuevas = [r for r in val if r[0] not in B]
    cambian = [r for r in val if r[0] in B and not igual(r, B[r[0]])]
    iguales = len(val) - len(nuevas) - len(cambian)
    solo_base = sorted(set(B) - {r[0] for r in F})
    print('Archivo: %s' % os.path.basename(ruta))
    print('Auditorias en el Excel: %d  (anteriores al corte, no se tocan: %d)' % (len(F), len(F) - len(val)))
    print('Desde el corte: %d  ->  nuevas %d, con cambio %d, iguales %d' % (len(val), len(nuevas), len(cambian), iguales))
    print('En la base y no en este Excel (se mantienen): %d' % len(solo_base))
    if val:
        print('Fechas desde el corte: %s a %s' % (min(r[1] for r in val), max(r[1] for r in val)))
    print('Suma de lote desde el corte: %s' % sum(r[9] for r in val))
    for r in cambian[:20]:
        t = B[r[0]]
        dif = [c for i, c in enumerate(CAMPOS[1:], 1) if str(t[c] or '') != str(r[i]) and not
               (c in ('lote', 'muestra', 'defectos') and float(t[c] or 0) == float(r[i]))]
        print('  cambia %s: %s' % (r[0], ', '.join(dif)))
    if len(sys.argv) > 2:
        with io.open(sys.argv[2], 'w', encoding='utf-8') as fh:
            json.dump(nuevas + cambian, fh, ensure_ascii=False, separators=(',', ':'))
        print('Filas por cargar guardadas en %s (%d)' % (sys.argv[2], len(nuevas) + len(cambian)))


if __name__ == '__main__':
    main()
