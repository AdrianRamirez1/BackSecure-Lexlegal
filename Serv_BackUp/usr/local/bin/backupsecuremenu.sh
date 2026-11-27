#!/bin/bash
# =====================================================================
# backupsecuremenu.sh - Menu de administracion de BackupSecure
#
# Reune en una sola pantalla las operaciones del sistema de copias:
# backup manual, listado, verificacion, restauracion, eventos y estado.
# Se ejecuta con un usuario con sudo (por ejemplo admin):
#     backupsecuremenu.sh
# Todas las operaciones sobre las copias se hacen como 'backupsvc'.
# =====================================================================
set -u
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

BIN="/usr/local/bin"
BASE="/srv/backups"
DB="backupsecure"

# Ejecuta un comando como el usuario de servicio
svc() { sudo -u backupsvc "$@"; }

# Consulta SQL con tabla formateada
sql() { svc mariadb -t -e "$1"; }

pausa() { echo; read -r -p "Pulsa Enter para volver al menu... " _; }

titulo() { echo; echo "=== $1 ==="; echo; }

# Pide un nombre de equipo mostrando los que existen
pedir_equipo() {
  local lista
  lista=$(svc mariadb -N -B -e "SELECT DISTINCT equipo_origen FROM $DB.backups ORDER BY 1;" 2>/dev/null | tr '\n' ' ')
  echo "Equipos con copias: ${lista:-ninguno}" >&2
  read -r -p "Equipo: " EQUIPO
  if [[ ! "$EQUIPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Nombre de equipo no valido." >&2
    return 1
  fi
  return 0
}

confirmar() {   # uso: confirmar "pregunta"
  local r
  read -r -p "$1 [s/N]: " r
  [[ "$r" =~ ^[sSyY]$ ]]
}

op_backup_diario() {
  titulo "Backup incremental (diario) manual"
  if confirmar "Lanzar ahora el backup incremental de todos los equipos?"; then
    svc "$BIN/backup-daily.sh"
    echo "Codigo de salida: $?"
  fi
  pausa
}

op_backup_completo() {
  titulo "Backup completo (semanal) manual"
  if confirmar "Lanzar ahora el backup completo de todos los equipos?"; then
    svc "$BIN/backup-weekly.sh"
    echo "Codigo de salida: $?"
  fi
  pausa
}

op_listar() {
  titulo "Copias registradas"
  read -r -p "Equipo (Enter = todos): " EQUIPO
  if [ -n "$EQUIPO" ] && [[ ! "$EQUIPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Nombre de equipo no valido."
  else
    svc "$BIN/restore.sh" --listar "$EQUIPO"
  fi
  pausa
}

op_verificar() {
  titulo "Verificacion de integridad"
  echo "1) Copias pendientes (completa: hash + descifrado)"
  echo "2) Todas las copias (completa)"
  echo "3) Solo hash, rapida, todas"
  read -r -p "Opcion [1-3]: " o
  case "$o" in
    1) svc "$BIN/verify-integrity.sh" ;;
    2) svc "$BIN/verify-integrity.sh" --todos ;;
    3) svc "$BIN/verify-integrity.sh" --todos --rapido ;;
    *) echo "Opcion no valida." ;;
  esac
  pausa
}

op_restaurar() {
  titulo "Restaurar un equipo"
  echo "La restauracion se hace SIEMPRE en una carpeta nueva dentro de"
  echo "$BASE/restauraciones/. Los equipos originales no se tocan."
  echo
  pedir_equipo || { pausa; return; }
  echo "Fecha: AAAA-MM-DD o 'AAAA-MM-DD HH:MM' (Enter = ultima copia)"
  read -r -p "Fecha: " FECHA
  read -r -p "Nombre de la carpeta (Enter = automatico): " NOMBRE

  local ARGS=(--restaurar "$EQUIPO")
  [ -n "$FECHA" ]  && ARGS+=(--fecha "$FECHA")
  [ -n "$NOMBRE" ] && ARGS+=(--nombre "$NOMBRE")

  echo
  if confirmar "Restaurar '$EQUIPO' ${FECHA:+a fecha $FECHA}?"; then
    svc "$BIN/restore.sh" "${ARGS[@]}"
  fi
  pausa
}

op_prueba() {
  titulo "Prueba de restauracion (compara con el espejo)"
  read -r -p "Equipo (Enter = todos): " EQUIPO
  if [ -n "$EQUIPO" ] && [[ ! "$EQUIPO" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Nombre de equipo no valido."
  else
    svc "$BIN/restore.sh" --prueba "$EQUIPO"
    echo "Codigo de salida: $?"
  fi
  pausa
}

op_eventos() {
  titulo "Ultimos eventos"
  echo "1) Todos   2) Solo errores y avisos"
  read -r -p "Opcion [1-2]: " o
  case "$o" in
    2) sql "SELECT id, fecha, nivel, mensaje FROM $DB.eventos WHERE nivel IN ('error','aviso') ORDER BY id DESC LIMIT 20;" ;;
    *) sql "SELECT id, fecha, nivel, mensaje FROM $DB.eventos ORDER BY id DESC LIMIT 20;" ;;
  esac
  pausa
}

op_restauraciones() {
  titulo "Historial de restauraciones"
  sql "SELECT r.id, r.fecha, b.equipo_origen AS equipo, r.backup_id AS copia, r.destino, r.usuario, r.estado FROM $DB.restauraciones r JOIN $DB.backups b ON b.id=r.backup_id ORDER BY r.id DESC LIMIT 20;"
  pausa
}

op_limpiar() {
  titulo "Borrar restauraciones antiguas"
  echo "Carpetas actuales en $BASE/restauraciones:"
  svc ls -1 "$BASE/restauraciones" 2>/dev/null || echo "(ninguna)"
  echo
  read -r -p "Carpeta a borrar (Enter = cancelar): " CARPETA
  [ -z "$CARPETA" ] && { pausa; return; }
  if [[ ! "$CARPETA" =~ ^[A-Za-z0-9._-]+$ ]] || [[ "$CARPETA" =~ ^\.+$ ]]; then
    echo "Nombre no valido."
  elif [ ! -d "$BASE/restauraciones/$CARPETA" ]; then
    echo "No existe esa carpeta."
  elif confirmar "Borrar $BASE/restauraciones/$CARPETA definitivamente?"; then
    svc rm -rf -- "$BASE/restauraciones/$CARPETA" && echo "Borrada."
  fi
  pausa
}

op_estado() {
  titulo "Estado del sistema"
  echo "--- RAID ---"
  grep -A2 '^md' /proc/mdstat 2>/dev/null || echo "Sin informacion de RAID"
  echo
  echo "--- Espacio en $BASE ---"
  df -h "$BASE" | tail -n +1
  echo
  echo "--- Ultima copia por equipo ---"
  sql "SELECT equipo_origen AS equipo, MAX(fecha) AS ultima, SUM(estado='error') AS con_error, COUNT(*) AS total FROM $DB.backups GROUP BY equipo_origen;"
  echo
  echo "--- Tareas programadas ---"
  grep -vE '^[[:space:]]*(#|$)' /etc/cron.d/backupsecure 2>/dev/null || echo "No hay /etc/cron.d/backupsecure"
  pausa
}

while true; do
  clear
  echo "=========================================="
  echo "   BackupSecure - Lex Legal Ramirez & Asoc."
  echo "=========================================="
  echo "  1) Backup incremental manual"
  echo "  2) Backup completo manual"
  echo "  3) Listar copias"
  echo "  4) Verificar integridad"
  echo "  5) Restaurar un equipo"
  echo "  6) Prueba de restauracion"
  echo "  7) Ver eventos"
  echo "  8) Historial de restauraciones"
  echo "  9) Estado del sistema (RAID, espacio, cron)"
  echo " 10) Borrar una carpeta de restauracion"
  echo "  0) Salir"
  echo "------------------------------------------"
  read -r -p "Opcion: " OPCION
  case "$OPCION" in
    1) op_backup_diario ;;
    2) op_backup_completo ;;
    3) op_listar ;;
    4) op_verificar ;;
    5) op_restaurar ;;
    6) op_prueba ;;
    7) op_eventos ;;
    8) op_restauraciones ;;
    9) op_estado ;;
    10) op_limpiar ;;
    0) echo "Hasta luego."; exit 0 ;;
    *) echo "Opcion no valida."; sleep 1 ;;
  esac
done
