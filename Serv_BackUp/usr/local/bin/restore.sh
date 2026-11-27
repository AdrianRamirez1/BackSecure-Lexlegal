#!/bin/bash
# =====================================================================
# restore.sh - Restauracion controlada de copias BackupSecure
#
# NUNCA sobrescribe los equipos originales: restaura en una carpeta nueva
# dentro de /srv/backups/restauraciones/ y registra la operacion en la
# tabla 'restauraciones' de la base de datos.
#
# Uso (como backupsvc, por ejemplo: sudo -u backupsvc restore.sh ...):
#   restore.sh --listar [equipo]
#   restore.sh --restaurar equipo [--fecha "AAAA-MM-DD [HH:MM[:SS]]"] [--nombre carpeta]
#   restore.sh --prueba [equipo]
#
#  --restaurar  Reconstruye el estado de 'equipo' en la fecha indicada
#               (por defecto, la ultima copia). Aplica el backup completo
#               anterior y despues los incrementales, en orden.
#  --prueba     Restaura la ultima copia en una carpeta temporal y la
#               compara con el espejo; deja el resultado en 'eventos'.
# =====================================================================
set -u
set -o pipefail
export HOME=/var/lib/backupsvc
export PATH=/usr/local/bin:/usr/bin:/bin
cd / || exit 1

BASE="/srv/backups"
LOG="$BASE/logs/backup.log"
CLAVE="$HOME/.clave-gpg"
ESPEJO="$BASE/espejo"
DESTINO_BASE="$BASE/restauraciones"
USUARIO="${SUDO_USER:-$(id -un)}"

log() { echo "$(date '+%F %T') [restauracion] $*" | tee -a "$LOG"; }

sq() {   # escapa un texto para meterlo entre comillas simples en SQL
  local s="${1//\\/\\\\}"
  printf '%s' "${s//\'/\'\'}"
}

db() { mariadb -e "$1" 2>>"$LOG"; }

evento() { db "INSERT INTO eventos (fecha, nivel, mensaje) VALUES (NOW(), '$1', '$(sq "$2")');"; }

registrar() {   # uso: registrar backup_id destino estado
  db "INSERT INTO restauraciones (fecha, backup_id, destino, usuario, estado) VALUES (NOW(), $1, '$(sq "$2")', '$(sq "$USUARIO")', '$3');"
}

uso() {
  echo "Uso:"
  echo "  $0 --listar [equipo]"
  echo "  $0 --restaurar equipo [--fecha \"AAAA-MM-DD [HH:MM[:SS]]\"] [--nombre carpeta]"
  echo "  $0 --prueba [equipo]"
}

validar_nombre() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }

normalizar_fecha() {
  local f="$1"
  local r1='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
  local r2='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$'
  local r3='^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$'
  if   [[ "$f" =~ $r1 ]]; then echo "$f 23:59:59"
  elif [[ "$f" =~ $r2 ]]; then echo "$f:59"
  elif [[ "$f" =~ $r3 ]]; then echo "$f"
  else return 1
  fi
}

listar() {
  local filtro=""
  if [ -n "${1:-}" ]; then
    validar_nombre "$1" || { echo "Nombre de equipo no valido"; exit 1; }
    filtro="WHERE equipo_origen='$1'"
  fi
  mariadb -t -e "SELECT id, fecha, equipo_origen AS equipo, tipo, tamano_bytes AS bytes, estado FROM backups $filtro ORDER BY id DESC LIMIT 40;"
}

# Aplica la cadena completo + incrementales de un equipo hasta una fecha.
# uso: aplicar_cadena equipo "AAAA-MM-DD HH:MM:SS" carpeta_destino
aplicar_cadena() {
  local EQ="$1" FECHA="$2" DEST="$3"
  local BASE_ID FILAS=() f ID RUTA HASH TIPO ESTADO CALC

  BASE_ID=$(mariadb -N -B -e "SELECT id FROM backups WHERE equipo_origen='$EQ' AND tipo='completo' AND ruta <> '-' AND fecha <= '$FECHA' ORDER BY id DESC LIMIT 1;" 2>>"$LOG")
  if [ -z "$BASE_ID" ]; then
    log "ERROR: no hay ninguna copia completa de '$EQ' anterior a $FECHA"
    return 1
  fi

  mapfile -t FILAS < <(mariadb -N -B -e "SELECT id, ruta, hash_sha256, tipo, estado FROM backups WHERE equipo_origen='$EQ' AND ruta <> '-' AND fecha <= '$FECHA' AND id >= $BASE_ID ORDER BY id;" 2>>"$LOG")

  # 1) Comprobar toda la cadena ANTES de extraer nada
  for f in "${FILAS[@]}"; do
    IFS=$'\t' read -r ID RUTA HASH TIPO ESTADO <<< "$f"
    if [ "$ESTADO" = "error" ]; then
      log "ERROR: la copia #$ID esta marcada con error; elige una fecha anterior a ella"
      return 1
    fi
    if [ ! -f "$RUTA" ]; then
      log "ERROR: falta el fichero de la copia #$ID: $RUTA"
      return 1
    fi
    CALC=$(sha256sum "$RUTA" | cut -d' ' -f1)
    if [ "$CALC" != "$HASH" ]; then
      log "ERROR: el SHA-256 de la copia #$ID no coincide (fichero alterado)"
      evento "error" "Restauracion abortada: copia #$ID alterada"
      return 1
    fi
  done
  log "Cadena de ${#FILAS[@]} copia(s) para '$EQ' hasta $FECHA (completo #$BASE_ID)"

  # 2) Extraer en orden
  mkdir -p "$DEST" || { log "ERROR: no se pudo crear $DEST"; return 1; }
  for f in "${FILAS[@]}"; do
    IFS=$'\t' read -r ID RUTA HASH TIPO ESTADO <<< "$f"
    if gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$CLAVE" -d "$RUTA" 2>>"$LOG" \
       | tar --listed-incremental=/dev/null -xz -C "$DEST" -f - 2>>"$LOG"; then
      registrar "$ID" "$DEST" "ok"
      log "  aplicada copia #$ID ($TIPO)"
    else
      registrar "$ID" "$DEST" "error"
      evento "error" "Restauracion de '$EQ' fallida al aplicar la copia #$ID"
      log "ERROR: fallo al descifrar o extraer la copia #$ID"
      return 1
    fi
  done
  return 0
}

cmd_restaurar() {
  local EQ="${1:-}"; shift || true
  local FECHA="" NOMBRE="" DEST
  [ -n "$EQ" ] && validar_nombre "$EQ" || { echo "Falta el equipo o no es valido"; uso; exit 1; }
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --fecha)  FECHA="${2:-}"; shift 2 ;;
      --nombre) NOMBRE="${2:-}"; shift 2 ;;
      *) echo "Opcion desconocida: $1"; uso; exit 1 ;;
    esac
  done
  if [ -n "$FECHA" ]; then
    FECHA=$(normalizar_fecha "$FECHA") || { echo "Fecha no valida (usa AAAA-MM-DD o AAAA-MM-DD HH:MM[:SS])"; exit 1; }
  else
    FECHA=$(date '+%F %T')
  fi
  if [ -z "$NOMBRE" ]; then
    NOMBRE="${EQ}_$(date +%F_%H%M%S)"
  fi
  validar_nombre "$NOMBRE" || { echo "El nombre de carpeta solo admite letras, numeros, punto, guion y guion bajo"; exit 1; }

  DEST="$DESTINO_BASE/$NOMBRE"
  if [ -d "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    echo "La carpeta $DEST ya existe y no esta vacia. Elige otro --nombre."
    exit 1
  fi

  log "Restauracion de '$EQ' a fecha $FECHA solicitada por $USUARIO"
  if aplicar_cadena "$EQ" "$FECHA" "$DEST"; then
    evento "info" "Restauracion de '$EQ' ($FECHA) completada en $DEST por $USUARIO"
    log "OK: restauracion completada en $DEST"
    echo "Los ficheros restaurados estan en: $DEST"
    echo "Los equipos originales NO se han modificado."
    exit 0
  else
    log "La restauracion NO se ha completado (puede haber ficheros parciales en $DEST)"
    exit 1
  fi
}

cmd_prueba() {
  local EQUIPOS=() EQ TMP FALLOS=0 DIF
  USUARIO="prueba-automatica"

  # No probar mientras haya un backup en marcha: el espejo estaria a medias
  exec 9>"$BASE/state/backup.lock"
  flock -n 9 || { log "Hay un backup en ejecucion; se cancela la prueba"; exit 1; }

  if [ -n "${1:-}" ]; then
    validar_nombre "$1" || { echo "Nombre de equipo no valido"; exit 1; }
    EQUIPOS=("$1")
  else
    mapfile -t EQUIPOS < <(mariadb -N -B -e "SELECT DISTINCT equipo_origen FROM backups WHERE ruta <> '-' ORDER BY 1;" 2>>"$LOG")
  fi
  [ "${#EQUIPOS[@]}" -gt 0 ] || { log "No hay copias registradas para probar"; exit 1; }

  mkdir -p "$DESTINO_BASE"
  for EQ in "${EQUIPOS[@]}"; do
    TMP="$DESTINO_BASE/.prueba-$EQ-$$"
    rm -rf "$TMP"
    log "Prueba de restauracion de '$EQ'"
    if aplicar_cadena "$EQ" "$(date '+%F %T')" "$TMP"; then
      DIF=$(diff -rq "$ESPEJO/$EQ" "$TMP" 2>&1)
      if [ -z "$DIF" ]; then
        log "OK: '$EQ' restaurado y identico al espejo"
        evento "info" "Prueba de restauracion de '$EQ': correcta"
      else
        log "ERROR: '$EQ' restaurado con diferencias respecto al espejo:"
        echo "$DIF" | head -n 10 | tee -a "$LOG"
        evento "error" "Prueba de restauracion de '$EQ': diferencias con el espejo"
        FALLOS=$((FALLOS + 1))
      fi
    else
      evento "error" "Prueba de restauracion de '$EQ': no se pudo restaurar"
      FALLOS=$((FALLOS + 1))
    fi
    rm -rf "$TMP"
  done
  [ "$FALLOS" -eq 0 ]
}

# ---------- Programa principal ----------
CMD="${1:-}"
[ "$#" -gt 0 ] && shift
case "$CMD" in
  --listar)    listar "${1:-}" ;;
  --restaurar) [ -r "$CLAVE" ] || { echo "No se puede leer $CLAVE"; exit 1; }; cmd_restaurar "$@" ;;
  --prueba)    [ -r "$CLAVE" ] || { echo "No se puede leer $CLAVE"; exit 1; }; cmd_prueba "${1:-}" ;;
  *)           uso; exit 1 ;;
esac
