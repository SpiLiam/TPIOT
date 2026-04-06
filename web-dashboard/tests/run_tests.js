const mqtt = require('mqtt');
const net  = require('net');

const HOST  = process.env.MQTT_HOST  || 'localhost';
const PORT  = parseInt(process.env.MQTT_PORT  || '1883');
const TOPIC = process.env.MQTT_TOPIC || 'sensors/temperature';

// ─── Couleurs terminal ────────────────────────────────────────
const G = '\x1b[32m', R = '\x1b[31m', Y = '\x1b[33m', B = '\x1b[34m', NC = '\x1b[0m', BOLD = '\x1b[1m';

let passed = 0, failed = 0;

function ok(name)   { passed++; console.log(`  ${G}✓${NC} ${name}`); }
function fail(name, reason) { failed++; console.log(`  ${R}✗${NC} ${name}${reason ? ' — ' + reason : ''}`); }
function section(name) { console.log(`\n${BOLD}${B}▶ ${name}${NC}`); }

function timeout(ms, promise, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(new Error(`Timeout ${ms}ms`)), ms))
  ]);
}

// ─── Tests ───────────────────────────────────────────────────

async function testTcpConnectivity() {
  section('1. Connectivité TCP');
  return new Promise(resolve => {
    const sock = new net.Socket();
    const timer = setTimeout(() => {
      sock.destroy();
      fail(`TCP ${HOST}:${PORT}`, 'timeout 5s');
      resolve();
    }, 5000);
    sock.connect(PORT, HOST, () => {
      clearTimeout(timer);
      ok(`TCP ${HOST}:${PORT} accessible`);
      sock.destroy();
      resolve();
    });
    sock.on('error', err => {
      clearTimeout(timer);
      fail(`TCP ${HOST}:${PORT}`, err.message);
      resolve();
    });
  });
}

async function testMqttConnect() {
  section('2. Connexion MQTT');
  return new Promise(resolve => {
    const client = mqtt.connect(`mqtt://${HOST}:${PORT}`, {
      clientId: `test-connect-${Date.now()}`,
      connectTimeout: 8000,
    });
    const timer = setTimeout(() => {
      client.end(true);
      fail('MQTT connect', 'timeout 8s');
      resolve(null);
    }, 8000);
    client.on('connect', () => {
      clearTimeout(timer);
      ok('Connexion MQTT établie');
      resolve(client);
    });
    client.on('error', err => {
      clearTimeout(timer);
      fail('Connexion MQTT', err.message);
      client.end(true);
      resolve(null);
    });
  });
}

async function testMqttSubscribe(client) {
  section('3. Réception de messages (timeout 30s)');
  if (!client) { fail('Subscribe', 'pas de client connecté'); return; }
  return new Promise(resolve => {
    const timer = setTimeout(() => {
      fail(`Subscribe ${TOPIC}`, 'aucun message reçu en 30s — simulateur actif ?');
      resolve();
    }, 30000);
    client.subscribe(TOPIC, { qos: 1 }, (err) => {
      if (err) { clearTimeout(timer); fail(`Subscribe ${TOPIC}`, err.message); resolve(); return; }
      ok(`Abonnement à "${TOPIC}" OK`);
    });
    client.on('message', (topic, payload) => {
      clearTimeout(timer);
      try {
        const data = JSON.parse(payload.toString());
        ok(`Message reçu : ${JSON.stringify(data)}`);
        if (typeof data.value === 'number') ok(`Valeur numérique : ${data.value}°C`);
        else fail('Champ "value" numérique', `reçu: ${typeof data.value}`);
        if (data.sensor_id) ok(`Champ "sensor_id" présent : ${data.sensor_id}`);
        else fail('Champ "sensor_id" manquant');
        if (data.timestamp) ok(`Champ "timestamp" présent`);
        else fail('Champ "timestamp" manquant');
      } catch (e) {
        fail('Parsing JSON payload', e.message);
      }
      resolve();
    });
  });
}

async function testMqttPublishReceive(client) {
  section('4. Publish / Receive roundtrip');
  if (!client) { fail('Roundtrip', 'pas de client connecté'); return; }
  const testTopic = `test/roundtrip-${Date.now()}`;
  const testPayload = JSON.stringify({ ping: true, ts: Date.now() });
  return new Promise(resolve => {
    const timer = setTimeout(() => {
      fail('Roundtrip publish/receive', 'timeout 5s');
      resolve();
    }, 5000);
    client.subscribe(testTopic, { qos: 1 }, () => {
      client.publish(testTopic, testPayload, { qos: 1 }, (err) => {
        if (err) { clearTimeout(timer); fail('Publish', err.message); resolve(); }
      });
    });
    client.on('message', (topic, payload) => {
      if (topic !== testTopic) return;
      clearTimeout(timer);
      if (payload.toString() === testPayload) ok('Roundtrip publish→subscribe OK');
      else fail('Roundtrip payload', 'payload différent');
      resolve();
    });
  });
}

async function testMultipleConnections() {
  section('5. Connexions multiples (5 clients simultanés)');
  const clients = [];
  const promises = Array.from({ length: 5 }, (_, i) =>
    new Promise(resolve => {
      const c = mqtt.connect(`mqtt://${HOST}:${PORT}`, {
        clientId: `test-multi-${i}-${Date.now()}`,
        connectTimeout: 8000,
      });
      const t = setTimeout(() => { c.end(true); resolve(false); }, 8000);
      c.on('connect', () => { clearTimeout(t); clients.push(c); resolve(true); });
      c.on('error',   () => { clearTimeout(t); resolve(false); });
    })
  );
  const results = await Promise.all(promises);
  const nb = results.filter(Boolean).length;
  if (nb === 5) ok(`5/5 connexions simultanées établies`);
  else          fail(`Connexions simultanées`, `${nb}/5 réussies`);
  clients.forEach(c => c.end(true));
}

async function testMessageRate() {
  section('6. Débit de messages (fenêtre 20s)');
  return new Promise(resolve => {
    const client = mqtt.connect(`mqtt://${HOST}:${PORT}`, {
      clientId: `test-rate-${Date.now()}`,
      connectTimeout: 8000,
    });
    let count = 0;
    client.on('connect', () => {
      client.subscribe(TOPIC, { qos: 1 });
      setTimeout(() => {
        client.end(true);
        if (count === 0) fail('Débit', 'aucun message en 20s');
        else {
          ok(`${count} message(s) reçu(s) en 20s (≈ ${(count / 20).toFixed(2)} msg/s)`);
          if (count >= 3) ok('Débit suffisant (≥ 1 msg/5s)');
          else            fail('Débit insuffisant', `attendu ≥ 4, reçu ${count}`);
        }
        resolve();
      }, 20000);
    });
    client.on('message', () => count++);
    client.on('error', () => { fail('Débit client', 'erreur connexion'); resolve(); });
  });
}

// ─── Runner ──────────────────────────────────────────────────
async function main() {
  console.log(`\n${BOLD}════════════════════════════════════════${NC}`);
  console.log(`${BOLD}  IoT MQTT — Batterie de tests${NC}`);
  console.log(`${BOLD}════════════════════════════════════════${NC}`);
  console.log(`  Broker : ${HOST}:${PORT}`);
  console.log(`  Topic  : ${TOPIC}\n`);

  await testTcpConnectivity();
  const client = await testMqttConnect();
  await testMqttSubscribe(client);
  await testMqttPublishReceive(client);
  if (client) client.end(true);
  await testMultipleConnections();
  await testMessageRate();

  console.log(`\n${BOLD}════════════════════════════════════════${NC}`);
  console.log(`  ${G}Réussis${NC} : ${passed}`);
  console.log(`  ${R}Échoués${NC} : ${failed}`);
  console.log(`${BOLD}════════════════════════════════════════${NC}\n`);
  process.exit(failed > 0 ? 1 : 0);
}

main().catch(err => { console.error(err); process.exit(1); });
