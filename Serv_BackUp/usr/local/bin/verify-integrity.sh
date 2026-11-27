#!/bin/bash
# =====================================================================
# verify-integrity.sh
# Verifica las copias registradas en la base de datos:
#   1) El SHA-256 del fichero coincide con el guardado en la BD y en .sha256
#   2) (salvo --rapido) El fichero se puede descifrar y su tar se puede leer
# Si todo va bien, marca la copia como 'verificado'; si no, como 'error'.
#
# Uso (como usuario backupsvc):
#   verify-integrity.sh            -> copias con estado 'ok' (aun sin verificar)
#   verify-integrity.sh --todos    -> tambien las ya verificadas
#   verify-integrity.sh --rapido   -> solo comprueba el hash (sin descifrar)
# =====================================================================
set -u
set -o pipefail
export HOME=/var/lib/backupsvc
export PATH=/usr/local/bin:/usr/bin:/bin
cd / || exit 1

BASE="/srv/backups"
LOG="$BASE/logs/backup.log"
CLAVE="$HOME/.clave-gpg"

RAPIDO=0
TODOS=0
for a in "$@"; do
  case "$a" in
    --rapido) RAPIDO=1 ;;
    --todos)  TODOS=1 ;;
    *) echo "Uso: $0 [--todos] [--rapido]"; exit 1 ;;
  esac
done

log() { echo "$(date '+%F %T') [verificacion] $*" | tee -a "$LOG"; }
db()  { mariadb -e "$1" 2>>"$LOG"; }
evento() {
  local msg="${2//\'/\'\'}"
  db "INSERT INTO eventos (fecha, nivel, mensaje) VALUES (NOW(), '$1', '$msg');"
}

[ -r "$CLAVE" ] || { log "No se puede leer la clave de cifrado $CLAVE"; exit 1; }

if [ "$TODOS" -eq 1 ]; then
  FILTRO="estado IN ('ok','verificado')"
else
  FILTRO="estado = 'ok'"
fi

OK=0; MAL=0; AUSENTES=0

marcar_error() {   # uso: marcar_error id ruta "motivo"
  log "ERROR: copia #$1 ($2): $3"
  db "UPDATE backups SET estado='error' WHERE id=$1;"
  evento "error" "Verificacion: copia #$1 ($2): $3"
  MAL=$((MAL + 1))
}

log "Inicio de la verificacion (modo: $([ "$RAPIDO" -eq 1 ] && echo rapido || echo completo), $([ "$TODOS" -eq 1 ] && echo todas || echo pendientes))"

# Las filas se leen por el descriptor 3 para que ningun comando de dentro
# del bucle consuma la lista
while IFS=$'\t' read -r ID RUTA HASH <&3; do
  [ -z "$ID" ] && continue

  if [ ! -f "$RUTA" ]; then
    log "AVISO: copia #$ID: fichero no encontrado (retencion o borrado): $RUTA"
    AUSENTES=$((AUSENTES + 1))
    continue
  fi

  CALC=$(sha256sum "$RUTA" | cut -d' ' -f1)
  if [ "$CALC" != "$HASH" ]; then
    marcar_error "$ID" "$RUTA" "el SHA-256 no coincide con el registrado en la base de datos"
    continue
  fi

  if [ -f "$RUTA.sha256" ] && [ "$(cut -d' ' -f1 "$RUTA.sha256")" != "$HASH" ]; then
    marcar_error "$ID" "$RUTA" "el fichero .sha256 no coincide con la base de datos"
    continue
  fi

  if [ "$RAPIDO" -eq 0 ]; then
    if ! gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$CLAVE" -d "$RUTA" 2>/dev/null | tar tz >/dev/null 2>&1; then
      marcar_error "$ID" "$RUTA" "no se pudo descifrar o leer el contenido"
      continue
    fi
  fi

  db "UPDATE backups SET estado='verificado' WHERE id=$ID;"
  log "OK: copia #$ID verificada ($(basename "$RUTA"))"
  OK=$((OK + 1))
done 3< <(mariadb -N -B -e "SELECT id, ruta, hash_sha256 FROM backups WHERE $FILTRO AND ruta <> '-' ORDER BY id;" 2>>"$LOG")

log "Resumen: $OK verificadas, $MAL con error, $AUSENTES ausentes"
if [ "$MAL" -eq 0 ]; then
  evento "info" "Verificacion terminada: $OK correctas, $AUSENTES ausentes"
  exit 0
else
  evento "error" "Verificacion terminada con $MAL copia(s) con error"
  exit 1
fi
