# Intercom IP

Sistema de intercom IP profesional basado en mediasoup (SFU WebRTC).
Clientes web (PWA), Android, iOS y bridge para matrices de audio hardware.

---

## Arquitectura

```
                        ┌─────────────────────────────────────┐
                        │        Servidor (Docker)            │
                        │                                     │
 Navegador/App ───HTTPS──▶ Nginx ──▶ Backend Node.js          │
      │                 │    │         ├─ mediasoup (SFU)     │
      │                 │    │         ├─ SQLite (usuarios)   │
      └──WebRTC/UDP────▶│    │         └─ WebSocket signaling │
                        │    │                                │
                        │  Coturn (TURN) ◀── NAT traversal    │
                        └─────────────────────────────────────┘
                                        ▲
 Matriz HW ──▶ TieLine Bridge ──RTP/Opus─┘
 (Dante/MADI)    (Mac o Linux)
```

### Componentes

- **Backend** — Node.js + mediasoup SFU + API REST + WebSocket signaling
- **Nginx** — Reverse proxy HTTPS, sirve el frontend PWA
- **Coturn** — TURN server para NAT traversal
- **Frontend** — Flutter Web (PWA), también compilable como APK/iOS
- **Management** — Panel web de gestión (Python, puerto 9090)
- **TieLine Bridge** — Conecta matrices de audio hardware al intercom

---

## 1. Requisitos del servidor

### Hardware mínimo
- CPU: 2 cores
- RAM: 2 GB
- Disco: 5 GB
- Red: Ethernet (recomendado IP fija)

### Software
- Ubuntu 20.04+ o Debian 11+
- Docker y Docker Compose (el instalador los instala automáticamente)

### Puertos necesarios
Abrir en firewall/router:

- `8443/tcp` — HTTPS (interfaz web + WebSocket)
- `8080/tcp` — HTTP
- `10000-10200/udp` — WebRTC media (mediasoup)
- `3478/tcp+udp` — TURN server
- `49152-49200/udp` — TURN relay
- `9090/tcp` — Panel de gestión (opcional)

---

## 2. Instalación del servidor

### 2.1 Desde paquete (recomendado)

```bash
# Descomprimir el paquete
tar xzf intercom-YYYYMMDD-HHMM.tar.gz
cd intercom-YYYYMMDD-HHMM

# Ejecutar instalador
chmod +x install.sh
./install.sh
```

El instalador pregunta:
1. **IP del servidor** — IP de la interfaz de red (auto-detecta)
2. **Puerto HTTPS** — por defecto 8443
3. **Puerto HTTP** — por defecto 8080
4. **Usuario admin** — por defecto `admin`
5. **Contraseña admin** — por defecto `admin`

Después automáticamente:
- Instala Docker si no existe
- Genera certificado SSL autofirmado (válido 10 años)
- Genera JWT secret y TURN password aleatorios
- Construye contenedores Docker
- Arranca todos los servicios
- Instala panel de gestión como servicio systemd

### 2.2 Desde repositorio (desarrollo)

```bash
git clone <repo> intercom-janus
cd intercom-janus

# Compilar frontend
cd flutter_app
flutter build web --release
cd ..

# Instalar
./install.sh
```

---

## 3. Gestión del servidor

### Comandos principales

```bash
./intercom.sh start     # Arrancar servicios
./intercom.sh stop      # Parar servicios
./intercom.sh restart   # Reiniciar servicios
./intercom.sh rebuild   # Reconstruir contenedores (tras cambios de código)
./intercom.sh logs      # Ver logs en tiempo real
./intercom.sh status    # Ver estado de contenedores
```

### Archivos de configuración

- `.env` — Variables de entorno (puertos, credenciales, JWT secret)
- `docker-compose.yml` — Definición de servicios Docker
- `nginx/nginx.conf` — Configuración del reverse proxy
- `coturn/turnserver.conf` — Configuración del TURN server
- `backend/db/intercom.db` — Base de datos SQLite (usuarios, permisos, grupos)

### Modificar configuración

```bash
# Editar variables
nano .env

# Aplicar cambios
./intercom.sh restart
```

### Certificado SSL

El instalador genera un certificado autofirmado. Para usar un certificado real:

```bash
# Reemplazar estos archivos
nginx/certs/cert.pem    # Certificado
nginx/certs/key.pem     # Clave privada

# Reiniciar
./intercom.sh restart
```

---

## 4. Primer acceso y configuración inicial

### 4.1 Acceder al panel web

1. Abrir `https://IP_SERVIDOR:8443` en Chrome/Safari/Firefox
2. Aceptar la excepción del certificado autofirmado
3. Login con las credenciales admin configuradas durante la instalación

### 4.2 Crear usuarios

Desde el panel de administración:

1. Ir a **Admin** → **Usuarios**
2. Crear cada usuario con:
   - **Username** — identificador de login (ej: `thierry`)
   - **Display name** — nombre visible (ej: `Thierry`)
   - **Password** — contraseña de acceso
   - **Role** — `user` o `admin`
   - **Color** — color identificativo (opcional)

### 4.3 Configurar permisos

1. Ir a **Admin** → **Permisos**
2. La matriz muestra quién puede hablar con quién
3. Marcar las casillas correspondientes
4. Los permisos son bidireccionales (A→B y B→A se configuran por separado)

### 4.4 Crear grupos (opcional)

1. Ir a **Admin** → **Grupos**
2. Crear grupo con nombre y seleccionar miembros
3. Los usuarios pueden hablar al grupo completo

---

## 5. Clientes

### 5.1 Navegador web (PWA)

1. Abrir `https://IP_SERVIDOR:8443`
2. Login con usuario/password
3. En Chrome: menú → "Instalar aplicación" para acceso directo
4. Funciona en Chrome, Safari, Firefox, Edge

### 5.2 Android (APK)

```bash
cd flutter_app
flutter build apk --release
# APK en: build/app/outputs/flutter-apk/app-release.apk
```

Instalar el APK en el dispositivo Android (activar "Fuentes desconocidas").

### 5.3 iOS

```bash
cd flutter_app
flutter build ios --release
# Abrir en Xcode para firmar y desplegar
```

---

## 6. TieLine Bridge (matrices de audio hardware)

El TieLine Bridge conecta dispositivos de audio multicanal (Dante Virtual Soundcard,
Blackhole, MADI, RME, etc.) al sistema de intercom. Cada canal del dispositivo se
mapea a un usuario del intercom con detección VOX automática.

### 6.1 Instalación en macOS

**Requisitos**: macOS 12+ (Apple Silicon o Intel)

1. Copiar la carpeta `tieline-bridge/` al Mac
2. Copiar `logo.png` a la misma carpeta (opcional)
3. Doble-click en `setup_mac.command`

El instalador:
- Instala Homebrew, Python 3.12, PortAudio, Opus
- Crea entorno virtual con dependencias
- Genera `TieLine Bridge.app` en el Escritorio

**Uso**:
1. Abrir **TieLine Bridge** desde el Escritorio
2. Configurar usuario/password en los canales (ej: `MTX_1` / `changeme`)
3. Pulsar **↻ Usuarios** para cargar la lista del servidor
4. Seleccionar target de cada canal en el dropdown
5. Pulsar **▶ Conectar**

### 6.2 Instalación en Linux

**Opción A — Paquete .deb** (recomendado):

```bash
sudo dpkg -i tieline-bridge/tieline-bridge_1.0_all.deb
sudo apt-get install -f    # instalar dependencias
tieline wizard             # asistente de configuración
tieline start              # arrancar servicio
```

**Opción B — Script**:

```bash
sudo bash tieline-bridge/setup_linux.sh
tieline wizard
tieline start
```

**Comandos de gestión**:

```bash
tieline wizard    # Asistente de configuración
tieline devices   # Ver dispositivos de audio
tieline test      # Probar en modo interactivo
tieline start     # Iniciar servicio (auto-arranque)
tieline stop      # Detener
tieline restart   # Reiniciar
tieline logs      # Ver logs en tiempo real
tieline config    # Editar config.json
```

### 6.3 Configuración del bridge

Archivo `config.json`:

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

**Campos**:
- `server` — URL HTTPS del servidor intercom
- `input_device` / `output_device` — Nombre o ID del dispositivo de audio
- `num_device_channels` — Canales totales (2, 4, 8, 16, 32, 64)
- `channels[].index` — Canal del dispositivo (1-based)
- `channels[].username/password` — Credenciales del usuario intercom
- `channels[].target_type` — `user` o `group`
- `channels[].target_id` — ID del usuario/grupo destino
- `channels[].vox_threshold_db` — Umbral VOX en dB
- `channels[].vox_hold_ms` — Retención VOX en ms

### 6.4 Crear usuarios para el bridge

En el panel admin del intercom, crear usuarios dedicados para la matriz:

- `MTX_1` / `changeme` — Canal 1
- `MTX_2` / `changeme` — Canal 2
- `MTX_3` / `changeme` — Canal 3
- `MTX_4` / `changeme` — Canal 4

Luego configurar permisos para que estos usuarios puedan hablar con los destinos.

---

## 7. Generar paquete de distribución

Para crear un paquete instalable:

```bash
# Asegurar que el frontend está compilado
cd flutter_app && flutter build web --release && cd ..

# Generar paquete
./package.sh
```

El paquete `.tar.gz` resultante contiene todo lo necesario para instalar
en un servidor nuevo: backend, frontend, TURN, management y TieLine Bridge.

---

## 8. Solución de problemas

### El navegador no conecta
- Verificar que se aceptó la excepción del certificado SSL
- Verificar que los puertos están abiertos: `./intercom.sh status`
- Ver logs: `./intercom.sh logs`

### No hay audio
- Verificar permisos de micrófono en el navegador
- Verificar que los puertos UDP 10000-10200 están abiertos
- Si hay NAT, verificar que TURN funciona: logs de coturn

### TieLine Bridge no conecta
- Verificar que el servidor es accesible: `curl -k https://IP:8443/api/health`
- Verificar credenciales del usuario MTX
- Ver logs: `tieline logs` (Linux) o terminal (Mac)
- Verificar puertos UDP 10000-10200 accesibles desde el bridge

### Reiniciar todo

```bash
./intercom.sh rebuild
```

### Backup de la base de datos

```bash
cp backend/db/intercom.db backup-$(date +%Y%m%d).db
```

---

## 9. Estructura de archivos

```
intercom/
├── backend/                 # Backend Node.js + mediasoup
│   ├── src/
│   │   ├── server.js        # Punto de entrada
│   │   ├── config.js        # Configuración
│   │   ├── database.js      # SQLite
│   │   ├── routes/          # API REST (auth, admin, rooms)
│   │   ├── ws/              # WebSocket signaling
│   │   └── services/        # mediasoup, permisos
│   ├── db/                  # Base de datos SQLite
│   ├── Dockerfile
│   └── package.json
├── nginx/                   # Reverse proxy
│   ├── nginx.conf
│   ├── certs/               # Certificados SSL
│   └── Dockerfile
├── coturn/                  # TURN server
│   └── turnserver.conf
├── flutter_app/             # Frontend Flutter
│   └── build/web/           # PWA compilada
├── management/              # Panel de gestión
│   ├── server.py
│   └── index.html
├── tieline-bridge/          # Bridge audio hardware
│   ├── bridge_gui.py        # GUI macOS (customtkinter)
│   ├── bridge.py            # CLI Linux (headless)
│   ├── channel.py           # Lógica por canal
│   ├── audio_engine.py      # Motor audio multicanal
│   ├── opus_codec.py        # Codec Opus (ctypes)
│   ├── rtp_handler.py       # RTP packetizer
│   ├── config.json          # Configuración bridge
│   ├── setup_mac.command    # Instalador macOS
│   ├── setup_linux.sh       # Instalador Linux
│   └── build_deb.sh         # Generador .deb
├── docker-compose.yml       # Servicios Docker
├── install.sh               # Instalador del servidor
├── intercom.sh              # Script de gestión
├── package.sh               # Empaquetador
├── .env                     # Variables de entorno
└── logo.png                 # Logo del sistema
```
