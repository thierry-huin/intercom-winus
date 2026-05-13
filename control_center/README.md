# Winus Intercom — Control Center

GUI en Python (customtkinter) que agrupa las acciones más frecuentes del
proyecto para no tener que recordar los ~14 scripts shell.

## Lanzar

```bash
/opt/winus-intercom/control_center/launch.sh
```

La primera vez crea un venv local en `./.venv` e instala `customtkinter`.

## Añadir al menú de Ubuntu (opcional)

```bash
sudo cp /opt/winus-intercom/control_center/winus-control-center.desktop \
        /usr/share/applications/
update-desktop-database ~/.local/share/applications 2>/dev/null || true
```

Después aparecerá "Winus Control Center" en el launcher.

## Funcionalidades

- **Build**: compila Flutter web + APK, .deb completo, .deb slim (server),
  .deb del tie-line-bridge.
- **Server**: start / stop / restart / rebuild del stack Docker local; ver
  logs de backend/nginx/coturn; editar `announced_ips` y `turn_host` en la BD
  (útil cuando la BD se queda con valores del otro servidor).
- **Install**: lista los `.deb` detectados en `/opt/winus-intercom/` y
  `tie-line-bridge/` con tamaño y fecha, y los instala con `sudo apt install -y`.
- **Deploy**: SSH/SCP a un servidor remoto (por defecto `winus.overon.es`).
  Sube el `.deb` slim más reciente, lo instala y puede rebuildear el backend
  remoto o traer logs.
- **Bridge**: abre la GUI del bridge, borra su `config.json`, recompila su
  `.deb`.
- **Panel de logs**: columna derecha con stdout/stderr en vivo, con colores
  (verde OK, rojo error, naranja warning). Botón **Stop** para mandar
  terminate() al proceso activo.

## Config persistente

Se guarda en `~/.config/winus-control-center.json`:

- `ssh_user`, `ssh_host`, `ssh_key`
- `announced_ips`, `turn_host` (últimos valores aplicados)

## Requisitos del sistema

- Python ≥ 3.9 con venv (ya suele estar en Ubuntu).
- `docker` con compose v2.
- Para deploy remoto: `ssh`, `scp`, clave configurada para el host.
