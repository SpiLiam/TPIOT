const express = require('express');
const mqtt    = require('mqtt');
const { WebSocketServer } = require('ws');
const http    = require('http');

let MQTT_HOST  = process.env.MQTT_HOST  || 'localhost';
let MQTT_PORT  = parseInt(process.env.MQTT_PORT  || '1883');
let MQTT_TOPIC = process.env.MQTT_TOPIC || 'sensors/temperature';
let MQTT_USER  = process.env.MQTT_USER  || '';
let MQTT_PASS  = process.env.MQTT_PASS  || '';
const MAX_HISTORY = 60;

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocketServer({ server });

app.use(express.json());
app.use(express.static('public'));

// ─── État ────────────────────────────────────────────────────
let history    = [];
let mqttStatus = 'connecting';
let lastError  = null;
let mqttClient = null;

// ─── MQTT ────────────────────────────────────────────────────
function connectMqtt(host, port, topic, user, pass) {
  if (mqttClient) {
    mqttClient.end(true);
    mqttClient = null;
  }
  MQTT_HOST  = host;
  MQTT_PORT  = port;
  MQTT_TOPIC = topic;
  if (user !== undefined) MQTT_USER = user;
  if (pass !== undefined) MQTT_PASS = pass;
  history    = [];
  mqttStatus = 'connecting';
  broadcast({ type: 'status', status: mqttStatus });

  const options = {
    clientId: `dashboard-${Date.now()}`,
    reconnectPeriod: 5000,
    connectTimeout: 10000,
  };
  if (MQTT_USER) { options.username = MQTT_USER; options.password = MQTT_PASS; }

  const client = mqtt.connect(`mqtt://${host}:${port}`, options);

  client.on('connect', () => {
    mqttStatus = 'connected';
    lastError  = null;
    console.log(`[MQTT] Connecté à ${host}:${port}`);
    client.subscribe(topic, { qos: 1 });
    broadcast({ type: 'status', status: mqttStatus });
    broadcast({ type: 'config', config: { host, port, topic, user: MQTT_USER } });
  });

  client.on('message', (_, payload) => {
    try {
      const data  = JSON.parse(payload.toString());
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

  mqttClient = client;
}

// ─── WebSocket ───────────────────────────────────────────────
function broadcast(msg) {
  const str = JSON.stringify(msg);
  wss.clients.forEach(ws => { if (ws.readyState === 1) ws.send(str); });
}

wss.on('connection', (ws) => {
  ws.send(JSON.stringify({
    type: 'init',
    status: mqttStatus,
    history,
    config: { host: MQTT_HOST, port: MQTT_PORT, topic: MQTT_TOPIC, user: MQTT_USER }
  }));
});

// ─── API REST ────────────────────────────────────────────────
app.get('/api/status', (_, res) => res.json({
  status: mqttStatus, error: lastError,
  host: MQTT_HOST, port: MQTT_PORT, topic: MQTT_TOPIC, user: MQTT_USER
}));

app.get('/api/history', (_, res) => res.json(history));

// Changer la config broker à chaud
app.post('/api/config', (req, res) => {
  const { host, port, topic, user, pass } = req.body;
  if (!host) return res.status(400).json({ error: 'host requis' });
  console.log(`[CONFIG] Nouveau broker : ${host}:${port || 1883} user=${user || '(none)'}`);
  connectMqtt(host, parseInt(port) || 1883, topic || 'sensors/temperature', user || '', pass || '');
  res.json({ ok: true, host, port: parseInt(port) || 1883, topic: topic || 'sensors/temperature', user: user || '' });
});

// ─── Démarrage ───────────────────────────────────────────────
connectMqtt(MQTT_HOST, MQTT_PORT, MQTT_TOPIC);
server.listen(3000, () => console.log('[HTTP] Dashboard sur http://localhost:3000'));
