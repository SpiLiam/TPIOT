const express = require('express');
const mqtt    = require('mqtt');
const { WebSocketServer } = require('ws');
const http    = require('http');

const MQTT_HOST  = process.env.MQTT_HOST || 'localhost';
const MQTT_PORT  = parseInt(process.env.MQTT_PORT || '1883');
const MQTT_TOPIC = process.env.MQTT_TOPIC || 'sensors/temperature';
const MAX_HISTORY = 60;

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocketServer({ server });

app.use(express.static('public'));

// ─── État ────────────────────────────────────────────────────
let history = [];
let mqttStatus = 'connecting';
let lastError  = null;

// ─── MQTT ────────────────────────────────────────────────────
const client = mqtt.connect(`mqtt://${MQTT_HOST}:${MQTT_PORT}`, {
  clientId: `dashboard-${Date.now()}`,
  reconnectPeriod: 5000,
  connectTimeout: 10000,
});

client.on('connect', () => {
  mqttStatus = 'connected';
  lastError  = null;
  console.log(`[MQTT] Connecté à ${MQTT_HOST}:${MQTT_PORT}`);
  client.subscribe(MQTT_TOPIC, { qos: 1 });
  broadcast({ type: 'status', status: mqttStatus });
});

client.on('message', (topic, payload) => {
  try {
    const data = JSON.parse(payload.toString());
    const point = {
      ts:        Date.now(),
      ts_iso:    new Date().toISOString(),
      value:     data.value,
      sensor_id: data.sensor_id || 'unknown',
      unit:      data.unit || 'celsius',
    };
    history.push(point);
    if (history.length > MAX_HISTORY) history.shift();
    broadcast({ type: 'measurement', data: point });
  } catch (e) {
    console.error('[MQTT] Payload invalide:', e.message);
  }
});

client.on('error', (err) => {
  lastError  = err.message;
  mqttStatus = 'error';
  console.error('[MQTT] Erreur:', err.message);
  broadcast({ type: 'status', status: mqttStatus, error: lastError });
});

client.on('offline', () => {
  mqttStatus = 'reconnecting';
  broadcast({ type: 'status', status: mqttStatus });
});

// ─── WebSocket ───────────────────────────────────────────────
function broadcast(msg) {
  const str = JSON.stringify(msg);
  wss.clients.forEach(ws => { if (ws.readyState === 1) ws.send(str); });
}

wss.on('connection', (ws) => {
  // Envoyer l'état actuel au nouveau client
  ws.send(JSON.stringify({ type: 'init', status: mqttStatus, history, config: { host: MQTT_HOST, port: MQTT_PORT, topic: MQTT_TOPIC } }));
});

// ─── API REST ────────────────────────────────────────────────
app.get('/api/status', (_, res) => res.json({ status: mqttStatus, error: lastError, host: MQTT_HOST, port: MQTT_PORT, topic: MQTT_TOPIC }));
app.get('/api/history', (_, res) => res.json(history));

server.listen(3000, () => console.log('[HTTP] Dashboard sur http://localhost:3000'));
