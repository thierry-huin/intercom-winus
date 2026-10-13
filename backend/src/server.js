const express = require('express');
const http = require('http');
const path = require('path');
const fs = require('fs');
const { WebSocketServer } = require('ws');
const cors = require('cors');
const config = require('./config');
const { initialize } = require('./database');
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const roomRoutes = require('./routes/rooms');
const pushRoutes = require('./routes/push');
const pushService = require('./services/push-service');
const { setupSignaling } = require('./ws/signaling');
const ms = require('./services/mediasoup-manager');

const app = express();
const server = http.createServer(app);

// Middleware
app.use(cors());
// Larger limit so company logo base64 uploads fit comfortably.
app.use(express.json({ limit: '8mb' }));

// Company logos (and future uploads) live next to the SQLite DB volume.
const uploadsRoot = path.join(__dirname, '..', 'db', 'uploads');
const companyLogosDir = path.join(uploadsRoot, 'company-logos');
fs.mkdirSync(companyLogosDir, { recursive: true });
app.use('/api/uploads', express.static(uploadsRoot, {
  maxAge: '1h',
  fallthrough: true,
}));

// Routes
app.use('/api/auth', authRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/rooms', roomRoutes);
app.use('/api/push', pushRoutes);

// Health check
app.get('/api/health', (req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// WebSocket for signaling
const wss = new WebSocketServer({ server, path: '/ws' });
setupSignaling(wss);

// Initialize database and start server
initialize();
pushService.init();

(async () => {
  await ms.init();
  server.listen(config.port, () => {
    console.log(`Intercom backend running on port ${config.port}`);
  });
})();
