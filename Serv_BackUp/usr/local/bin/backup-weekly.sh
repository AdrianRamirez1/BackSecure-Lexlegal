#!/bin/bash
# =====================================================================
# backup-daily.sh  /  backup-weekly.sh   (mismo fichero, enlace simbolico)
#
# Backup centralizado en modo "pull": el servidor de backup trae los datos
# de cada equipo por SSH + rsync, genera un tar (incremental diario o
# completo semanal), lo cifra con GPG (AES-256), calcula su SHA-256 y
# registra el resultado en la base de datos MariaDB.
#
# El modo depende del nombre con el que se ejecute:
#   backup-daily.sh   -> incremental (si no hay base previa, hace completo)
#   backup-weekly.sh  -> completo
#
# Se ejecuta como el usuario backupsvc.
# Equipos y rutas a copiar: /etc/backupsecure/origenes.list
#   formato:  nombre;ip;/ruta        (una linea por ruta)
# =====================================================================
set -u
cd / || exit 1
export HOME=/var/lib/backupsvc
export PATH=/usr/local/bin:/usr/bin:/bin

case "$(basename "$0")" in
  *weekly*) MODO="semanal" ;;
  *)        MODO="diario" ;;
esac

# ---------- CONFIGURACION ----------
BASE="/srv/backups"
ORIGENES="/etc/backupsecure/origenes.list"
CLAVE="$HOME/.clave-gpg"                  # clave de cifrado (chmod 600)
SSH_KEY="$HOME/.ssh/id_ed25519"
KNOWN_HOSTS="$HOME/.ssh/known_hosts"
USUARIO_REMOTO="backupuser"
RETENCION_DIARIOS=14                      # dias que se conservan los incrementales
RETENCION_SEMANALES=35                    # dias que se conservan los completos
# -----------------------------------

LOG="$BASE/logs/backup.log"
ESTADO="$BASE/state"
ESPEJO="$BASE/espejo"

mkdir -p "$BASE/daily" "$BASE/weekly" "$BASE/logs" "$ESTADO" "$ESPEJO" || exit 1

log() { echo "$(date '+%F %T') [$MODO] $*" | tee -a "$LOG"; }

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

db() { mariadb -e "$1" 2>>"$LOG"; }

evento() {   # uso: evento nivel "mensaje"
  db "INSERT INTO eventos (fecha, nivel, mensaje) VALUES (NOW(), '$1', '$(sql_escape "$2")');"
}

fallo() {    # uso: fallo equipo "mensaje" tipo
  log "ERROR en $1: $2"
  evento "error" "$1: $2"
  db "INSERT INTO backups (fecha, equipo_origen, tipo, ruta, cifrado, estado) VALUES (NOW(), '$(sql_escape "$1")', '$3', '-', 0, 'error');"
}

# ---------- Comprobaciones previas ----------
[ -r "$ORIGENES" ] || { log "No se puede leer $ORIGENES"; exit 1; }
[ -r "$CLAVE" ]    || { log "No se puede leer la clave de cifrado $CLAVE"; exit 1; }

# Evita dos backups a la vez
exec 9>"$ESTADO/backup.lock"
if ! flock -n 9; then
  log "Ya hay un backup en ejecucion, se cancela"
  exit 1
fi

# ---------- Backup de un equipo ----------
backup_equipo() {
  local EQ="$1" IP RUTAS=() FUENTES=() r RC ST INICIO DUR FECHA
  local SNAR SNAR_TMP TIPO DESTINO ARCHIVO TAM HASH

  IP=$(awk -F';' -v e="$EQ" '$0 !~ /^[[:space:]]*#/ && $1==e {print $2; exit}' "$ORIGENES")
  mapfile -t RUTAS < <(awk -F';' -v e="$EQ" '$0 !~ /^[[:space:]]*#/ && $1==e {print $3}' "$ORIGENES")

  # Tipo de copia: incremental solo si es modo diario y existe base previa
  SNAR="$ESTADO/$EQ.snar"
  SNAR_TMP="$SNAR.tmp"
  rm -f "$SNAR_TMP"
  if [ "$MODO" = "diario" ] && [ -f "$SNAR" ]; then
    TIPO="incremental"
    cp "$SNAR" "$SNAR_TMP"
  else
    TIPO="completo"
  fi

  INICIO=$(date +%s)
  log "== $EQ ($IP): inicio, tipo $TIPO"

  # 1) Traer los datos (el espejo solo transfiere lo que ha cambiado)
  mkdir -p "$ESPEJO/$EQ"
  for r in "${RUTAS[@]}"; do
    FUENTES+=("$USUARIO_REMOTO@$IP:$r")
  done

  rsync -aR --delete \
    -e "ssh -i $SSH_KEY -o UserKnownHostsFile=$KNOWN_HOSTS -o BatchMode=yes -o ConnectTimeout=10" \
    "${FUENTES[@]}" "$ESPEJO/$EQ/" 2>>"$LOG"
  RC=$?
  # 24 = ficheros que desaparecieron durante la copia: no es grave
  if [ "$RC" -ne 0 ] && [ "$RC" -ne 24 ]; then
    fallo "$EQ" "rsync termino con codigo $RC" "$TIPO"
    return 1
  fi

  # 2) Comprimir y cifrar (AES-256)
  if [ "$TIPO" = "completo" ]; then DESTINO="$BASE/weekly/$EQ"; else DESTINO="$BASE/daily/$EQ"; fi
  mkdir -p "$DESTINO"
  FECHA=$(date +%F_%H%M%S)
  ARCHIVO="$DESTINO/${EQ}_${FECHA}_${TIPO}.tar.gz.gpg"

  tar --listed-incremental="$SNAR_TMP" -C "$ESPEJO/$EQ" -czf - . 2>>"$LOG" \
    | gpg --batch --yes --quiet --pinentry-mode loopback \
          --passphrase-file "$CLAVE" --symmetric --cipher-algo AES256 \
          -o "$ARCHIVO" 2>>"$LOG"
  ST=("${PIPESTATUS[@]}")
  if [ "${ST[0]}" -ne 0 ] || [ "${ST[1]}" -ne 0 ]; then
    rm -f "$ARCHIVO" "$SNAR_TMP"
    fallo "$EQ" "fallo al crear o cifrar el archivo (tar=${ST[0]}, gpg=${ST[1]})" "$TIPO"
    return 1
  fi
  mv "$SNAR_TMP" "$SNAR"      # la base incremental solo avanza si todo fue bien

  # 3) Integridad: SHA-256 del fichero cifrado
  TAM=$(stat -c %s "$ARCHIVO")
  HASH=$(sha256sum "$ARCHIVO" | cut -d' ' -f1)
  echo "$HASH  $(basename "$ARCHIVO")" > "$ARCHIVO.sha256"
  chmod 640 "$ARCHIVO" "$ARCHIVO.sha256"

  # 4) Registro en la base de datos
  DUR=$(( $(date +%s) - INICIO ))
  if db "INSERT INTO backups (fecha, equipo_origen, tipo, ruta, tamano_bytes, hash_sha256, cifrado, estado, duracion_seg) VALUES (NOW(), '$(sql_escape "$EQ")', '$TIPO', '$(sql_escape "$ARCHIVO")', $TAM, '$HASH', 1, 'ok', $DUR);"; then
    log "== $EQ: OK -> $(basename "$ARCHIVO") ($TAM bytes, ${DUR}s)"
  else
    log "AVISO: la copia de $EQ se hizo, pero no se pudo registrar en la base de datos"
    return 1
  fi
}

# ---------- Programa principal ----------
mapfile -t EQUIPOS < <(grep -vE '^[[:space:]]*(#|$)' "$ORIGENES" | cut -d';' -f1 | sort -u)
ERRORES=0
for EQ in "${EQUIPOS[@]}"; do
  backup_equipo "$EQ" || ERRORES=$((ERRORES + 1))
done

# ---------- Retencion ----------
find "$BASE/daily"  -type f -name '*.gpg*' -mtime +"$RETENCION_DIARIOS"   -print -delete 2>>"$LOG" \
  | while read -r f; do log "Retencion: eliminado $f"; done
find "$BASE/weekly" -type f -name '*.gpg*' -mtime +"$RETENCION_SEMANALES" -print -delete 2>>"$LOG" \
  | while read -r f; do log "Retencion: eliminado $f"; done

if [ "$ERRORES" -eq 0 ]; then
  log "Backup $MODO terminado sin errores (${#EQUIPOS[@]} equipos)"
  evento "info" "Backup $MODO terminado sin errores"
  exit 0
else
  log "Backup $MODO terminado con $ERRORES equipo(s) con errores"
  exit 1
fi
