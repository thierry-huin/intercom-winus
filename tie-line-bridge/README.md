# TieLine Bridge

Bridge de audio multicanal para el sistema de intercom IP. Conecta matrices de audio hardware (Blackhole, Dante Virtual Soundcard, MADI, RME, etc.) al servidor de intercom via PlainTransport RTP.

Cada canal del dispositivo de audio se mapea a un usuario del intercom, con detección VOX automática para PTT.

---

## Instalación en macOS

### Requisitos
- macOS 12+ (Apple Silicon o Intel)
- Conexión a la red del servidor de intercom

### Pasos
1. Copia la carpeta `tie-line-bridge/` al Mac (ej: `~/Projects/intercom-flutter/tie-line-bridge/`)
2. Coloca el logo `logo.png` en la misma carpeta (opcional, para icono de la app)
3. Doble-click en `setup_mac.command`
4. El instalador hace todo automáticamente:
   - Instala Homebrew (si no existe)
   - Instala Python 3.12, PortAudio, Opus
   - Crea entorno virtual con dependencias
   - Genera `TieLine Bridge.app` en el Escritorio
   - Genera `TieLine Bridge.command` (respaldo)
5. Abre la app desde el Escritorio

### Uso (macOS)
1. Abre **TieLine Bridge** desde el Escritorio
2. Configura usuario y password en los canales que necesites (ej: MTX_1 / changeme)
3. Pulsa **↻ Usuarios** para cargar la lista de usuarios del servidor
4. Selecciona el target de cada canal en el dropdown
5. Pulsa **▶ Conectar**

---

## Instalación en Linux (Ubuntu/Debian)

### Requisitos
- Ubuntu 20.04+ o Debian 11+
- Dispositivo de audio ALSA (tarjeta de sonido multicanal, Dante, MADI)
- Conexión a la red del servidor de intercom

### Pasos
```bash
# 1. Copiar archivos al servidor
scp -r tie-line-bridge/ usuario@servidor:/tmp/

# 2. Instalar (requiere root)
ssh usuario@servidor
sudo bash /tmp/tie-line-bridge/setup_linux.sh

# 3. Configurar
tieline wizard
```

El instalador:
- Instala Python, PortAudio, Opus, ALSA
- Crea usuario de servicio `tieline` (grupo audio)
- Instala la aplicación en `/opt/tieline-bridge/`
- Configura servicio systemd `tieline-bridge`
- Instala comando `tieline` en `/usr/local/bin/`

### Comandos (Linux)
```bash
tieline wizard    # Asistente de configuración interactivo
tieline devices   # Listar dispositivos de audio
tieline test      # Ejecutar en modo interactivo (Ctrl+C para parar)
tieline start     # Iniciar servicio (arranca con el sistema)
tieline stop      # Detener servicio
tieline restart   # Reiniciar servicio
tieline status    # Ver estado del servicio
tieline logs      # Ver logs en tiempo real
tieline config    # Editar config.json manualmente
```

---

## Configuración (config.json)

```json
{
  "server": "https://192.168.4.8:8443",
  "input_device": "BlackHole 16ch",
  "output_device": "BlackHole 16ch",
  "num_device_channels": 16,
  "sample_rate": 48000,
  "channels": [
    {
      "index": 1,
      "username": "MTX_1",
      "password": "changeme",
      "target_type": "user",
      "target_id": 6,
      "vox_threshold_db": -40,
      "vox_hold_ms": 300
    }
  ]
}
```

### Campos
- **server**: URL del servidor de intercom (HTTPS)
- **input_device**: Nombre o ID del dispositivo de captura
- **output_device**: Nombre o ID del dispositivo de reproducción
- **num_device_channels**: Canales totales del dispositivo (2, 4, 8, 16, 32, 64)
- **channels[].index**: Número de canal del dispositivo (1-based)
- **channels[].username/password**: Credenciales del usuario de intercom
- **channels[].target_type**: `user` o `group`
- **channels[].target_id**: ID del usuario o grupo destino
- **channels[].vox_threshold_db**: Umbral VOX en dB (ej: -40)
- **channels[].vox_hold_ms**: Tiempo de retención VOX en ms

---

## Arquitectura

```
Matriz HW → [Blackhole/Dante/MADI] → TieLine Bridge → [RTP/Opus] → Servidor Intercom
                                                     ← [RTP/Opus] ←
```

Cada canal:
1. Login HTTP → obtiene token JWT
2. WebSocket → autenticación + señalización
3. PlainTransport (send) → produce audio Opus via RTP
4. PlainTransport (recv) → consume audio Opus via RTP
5. VOX → detecta actividad de voz → activa PTT automáticamente

### Archivos
- `bridge_gui.py` — Interfaz gráfica (customtkinter, macOS)
- `bridge.py` — CLI headless (Linux/servidor)
- `channel.py` — Lógica por canal (login, WS, PlainTransport, VOX)
- `audio_engine.py` — Motor de audio multicanal (sounddevice)
- `opus_codec.py` — Codec Opus via ctypes (compatible ARM64)
- `rtp_handler.py` — Empaquetado/desempaquetado RTP + UDP
- `config.json` — Configuración
- `setup_mac.command` — Instalador macOS
- `setup_linux.sh` — Instalador Linux
- `config_wizard.sh` — Asistente de configuración (Linux)
