# BackupSecure: copias de seguridad seguras para Lex Legal Ramírez & Asociados

Proyecto de 2.º ASIR. Sistema centralizado de copias de seguridad en un laboratorio VirtualBox con Debian 12.

## Qué hace
- El servidor de backup (BackUp, 172.16.10.20) va a buscar los datos a cada equipo por SSH (modelo pull, solo lectura).
- Copia con rsync, empaqueta con tar incremental, cifra con GPG (AES-256) y calcula el SHA-256.
- Registra cada copia, restauración y evento en MariaDB.
- Restaura siempre en una carpeta nueva, tras comprobar el hash de toda la cadena.
- Incluye un menú de administración en Bash.

## Estructura
Cada carpeta reproduce la ruta original de los ficheros en el equipo (por ejemplo, `Serv_BackUp/etc/fstab` es `/etc/fstab` de BackUp).

| Carpeta | Equipo | Contenido |
| --- | --- | --- |
| `Router_1/` | Router1 (firewall) | Interfaces, reglas nftables (política `drop`, NAT, DNAT a la DMZ y acceso VPN), reenvío de paquetes y servidor WireGuard (`wg0.conf` sin clave privada) |
| `Router_2/` | Router2 (interno) | Interfaces, reglas nftables (incluida la regla de la VPN hacia BackUp), reenvío de paquetes y relay DHCP |
| `Serv_DHCP/` | ServDHCP (172.16.10.10) | `dhcpd.conf`, interfaz de escucha, acceso restringido para las copias (wrapper, sudoers y clave pública) |
| `Serv_Web/` | lexlegal-web (DMZ, 172.16.100.10) | Interfaces y `wp-config.php` de WordPress (Apache, PHP, MariaDB), sin contraseñas ni claves |
| `Teletrabajo/` | Cliente de teletrabajo | Cliente WireGuard (`wg0.conf` sin clave privada) |
| `Serv_BackUp/` | BackUp (172.16.10.20) | RAID 1, fstab, cron, lista de equipos a copiar, estructura de la base de datos y scripts |

Los scripts del sistema están en `Serv_BackUp/usr/local/bin/`:
`backup-daily.sh`, `backup-weekly.sh`, `verify-integrity.sh`, `restore.sh` y `backupsecuremenu.sh`.

## Red
| Segmento | Subred |
| --- | --- |
| VLAN 10 CPD | 172.16.10.0/24 |
| VLAN 20 abogados junior | 172.16.20.0/24 |
| VLAN 30 abogados senior | 172.16.30.0/24 |
| VLAN 100 DMZ | 172.16.100.0/24 |
| Enlace Router1 – Router2 | 172.16.0.0/30 |

Las VLAN se simulan en VirtualBox con redes internas.

## Seguridad
Este repositorio **no contiene** contraseñas, claves privadas ni la clave de cifrado de las copias. Las claves SSH que aparecen son únicamente públicas. La contraseña de la base de datos del laboratorio es de pruebas y debe cambiarse en producción.

## Limitaciones conocidas
- La copia externa en la nube (regla 3-2-1) está diseñada pero no implementada.
- Los discos del RAID del laboratorio son virtuales sobre un mismo disco físico.
- El servidor web de la DMZ (WordPress), el acceso remoto por VPN WireGuard y el dominio `lex.local` (SRVLEX, Windows Server 2025) están montados en el laboratorio; sus configuraciones de Windows no se incluyen en este repositorio.
- El segundo factor con YubiKey y Fail2Ban quedan como mejoras futuras.
- ISC DHCP está descatalogado; en producción se sustituiría por Kea.
