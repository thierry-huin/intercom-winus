const express = require('express');
const http = require('http');
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
app.use(express.json());

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
