#!/bin/bash
# ============================================================
# IoT MQTT Architecture - Deploiement AWS CLI
# Architecture : VPC + DMZ + Private + NLB + MQTT GWs + Snort + Ingestion
# Region : us-east-1
# Usage  : bash deploy.sh
# ============================================================

set -euo pipefail

# ─── COULEURS ────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'; BOLD='\033[1m'

log()     { echo -e "${GREEN}[$(date '+%H:%M:%S')]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}═══ $* ═══${NC}\n"; }

# ─── CONFIGURATION ───────────────────────────────────────────
REGION="us-east-1"
AZ="us-east-1a"
AZ_B="us-east-1b"
PROJECT="iot-mqtt"
ENV="prod"

# CIDRs conformes au cahier des charges (10.1.0.0/16)
VPC_CIDR="10.1.0.0/16"
DMZ_CIDR="10.1.1.0/24"
DMZ_CIDR_B="10.1.3.0/24"
PRIVATE_CIDR="10.1.2.0/24"

# Nom de la key pair dans AWS (doit correspondre a labsuser.pem)
KEY_PAIR="${KEY_PAIR:-vockey}"

# Instances t2.micro (consigne du projet)
INSTANCE_TYPE_GW="t2.micro"
INSTANCE_TYPE_SNORT="t2.micro"
INSTANCE_TYPE_INGESTION="t2.micro"
INSTANCE_TYPE_BASTION="t2.micro"

# Credentials MQTT (a changer en prod)
MQTT_PASS_SENSOR="Sensor2024!"
MQTT_PASS_INGESTION="Ingestion2024!"
MQTT_PASS_DASHBOARD="Dashboard2024!"

STATE_FILE="./infra_state.env"
SCRIPT_DIR="$(pwd)/deploy_scripts"
mkdir -p "$SCRIPT_DIR"

# ─── SCRIPTS EMBARQUES (ecrits dans /tmp au lancement) ───────
write_userdata_scripts() {
cat > /tmp/userdata_mqtt_gw.sh << 'USERDATA_MQTT_GW_EOF'
#!/bin/bash
set -x
exec > /var/log/bootstrap.log 2>&1
apt-get update -y
apt-get install -y mosquitto mosquitto-clients amazon-cloudwatch-agent jq curl wget openssl
# SSM Agent (non inclus par defaut sur Ubuntu 22.04 Canonical)
wget -q https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb && rm -f amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
# Stopper mosquitto avant de reecrire la config (il demarre auto apres install)
systemctl stop mosquitto || true
mkdir -p /var/log/mosquitto /var/lib/mosquitto /etc/mosquitto/certs
chown mosquitto:mosquitto /var/log/mosquitto /var/lib/mosquitto

# ── Certificats TLS : CA + serveur ──────────────────────────
openssl genrsa -out /etc/mosquitto/certs/ca.key 2048 2>/dev/null
openssl req -new -x509 -days 365 -nodes \
  -key /etc/mosquitto/certs/ca.key \
  -out /etc/mosquitto/certs/ca.crt \
  -subj "/C=FR/ST=IDF/L=Paris/O=IoT-Lab/CN=IoT-CA" 2>/dev/null
openssl genrsa -out /etc/mosquitto/certs/server.key 2048 2>/dev/null
openssl req -new -key /etc/mosquitto/certs/server.key \
  -out /etc/mosquitto/certs/server.csr \
  -subj "/C=FR/ST=IDF/L=Paris/O=IoT-Lab/CN=mqtt-gateway" 2>/dev/null
openssl x509 -req -days 365 \
  -in /etc/mosquitto/certs/server.csr \
  -CA /etc/mosquitto/certs/ca.crt \
  -CAkey /etc/mosquitto/certs/ca.key \
  -CAcreateserial \
  -out /etc/mosquitto/certs/server.crt 2>/dev/null
chmod 600 /etc/mosquitto/certs/server.key /etc/mosquitto/certs/ca.key
chown -R mosquitto:mosquitto /etc/mosquitto/certs/

# ── Fichier de mots de passe MQTT ───────────────────────────
mosquitto_passwd -b -c /etc/mosquitto/passwd sensor   Sensor2024!
mosquitto_passwd -b    /etc/mosquitto/passwd ingestion Ingestion2024!
mosquitto_passwd -b    /etc/mosquitto/passwd dashboard Dashboard2024!
chmod 640 /etc/mosquitto/passwd
chown root:mosquitto /etc/mosquitto/passwd

# ── ACL : politique d'acces minimale par topic ───────────────
cat > /etc/mosquitto/acl << 'ACLEOF'
# Capteurs IoT : publication uniquement sur leurs topics
user sensor
topic write sensors/temperature
topic write devices/+/telemetry

# Ingestion : lecture de tous les topics
user ingestion
topic read #

# Dashboard/clients : lecture uniquement
user dashboard
topic read sensors/temperature
topic read devices/+/telemetry
ACLEOF
chmod 640 /etc/mosquitto/acl
chown root:mosquitto /etc/mosquitto/acl

# ── Configuration Mosquitto : 1883 (auth) + 8883 (TLS+auth) ─
cat > /etc/mosquitto/mosquitto.conf << 'MQTTCONF'
pid_file /run/mosquitto/mosquitto.pid
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log
log_type all

# Port MQTT plaintext (reseau interne + bridge)
listener 1883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
max_connections 500

# Port MQTT over TLS (clients externes — production)
listener 8883 0.0.0.0
allow_anonymous false
password_file /etc/mosquitto/passwd
acl_file /etc/mosquitto/acl
cafile /etc/mosquitto/certs/ca.crt
certfile /etc/mosquitto/certs/server.crt
keyfile /etc/mosquitto/certs/server.key
require_certificate false
max_connections 500
MQTTCONF
rm -f /etc/mosquitto/conf.d/*.conf
cat > /usr/local/bin/configure_bridge.sh << 'BRIDGESCRIPT'
#!/bin/bash
INGESTION_IP="$1"
[ -z "$INGESTION_IP" ] && { echo "Usage: $0 <ingestion_ip>"; exit 1; }
cat > /etc/mosquitto/conf.d/bridge.conf << BRIDGECONF
connection backend-bridge
address ${INGESTION_IP}:1883
topic # both 0
cleansession false
restart_timeout 10
BRIDGECONF
systemctl restart mosquitto
echo "Bridge configure vers $INGESTION_IP"
BRIDGESCRIPT
chmod +x /usr/local/bin/configure_bridge.sh
systemctl enable mosquitto
systemctl restart mosquitto
sleep 2
systemctl is-active mosquitto && echo "[OK] Mosquitto actif" || echo "[ERREUR] Mosquitto non demarre"

# ── Simulateur de temperature embarque (sans SSM) ──────────────
pip3 install paho-mqtt --quiet 2>&1 || true
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
mkdir -p /opt/iot-simulator
cat > /opt/iot-simulator/sensor_simulator.py << 'SIMEOF'
#!/usr/bin/env python3
import json, math, random, time, signal, sys, os
import paho.mqtt.client as mqtt

BROKER_HOST  = os.getenv('MQTT_BROKER', '127.0.0.1')
BROKER_PORT  = int(os.getenv('MQTT_PORT', '1883'))
TOPIC        = os.getenv('MQTT_TOPIC', 'sensors/temperature')
SENSOR_ID    = os.getenv('SENSOR_ID', 'temp-sensor-gw')
INTERVAL_SEC = 5
running = True

def on_connect(client, userdata, flags, rc):
    codes = {0:"Connecte", 1:"Mauvais protocole", 2:"ID invalide",
             3:"Serveur indisponible", 4:"Mauvais user/pass", 5:"Non autorise"}
    print(f"[MQTT] {codes.get(rc, f'Code {rc}')}", flush=True)

def on_disconnect(client, userdata, rc):
    if rc != 0:
        print(f"[MQTT] Deconnexion (code {rc}), reconnexion...", flush=True)

def generate_temperature():
    t = time.time()
    return round(22.0 + 4.0 * math.sin(2 * math.pi * t / 60) + random.uniform(-0.5, 0.5), 2)

def signal_handler(sig, frame):
    global running
    running = False

signal.signal(signal.SIGINT,  signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

while running:
    try:
        client = mqtt.Client(client_id=f"simulator-{SENSOR_ID}-{int(time.time())}")
        client.username_pw_set(os.getenv('MQTT_USER', 'sensor'), os.getenv('MQTT_PASS', 'Sensor2024!'))
        client.on_connect = on_connect
        client.on_disconnect = on_disconnect
        client.connect(BROKER_HOST, BROKER_PORT, keepalive=60)
        client.loop_start()
        print(f"[INFO] Publication sur '{TOPIC}' toutes les {INTERVAL_SEC}s", flush=True)
        while running:
            temp = generate_temperature()
            payload = json.dumps({
                "sensor_id": SENSOR_ID, "value": temp, "unit": "celsius",
                "timestamp": int(time.time()),
                "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            })
            result = client.publish(TOPIC, payload, qos=1)
            if result.rc == 0:
                print(f"[PUBLISH] {temp} C -> {TOPIC}", flush=True)
            time.sleep(INTERVAL_SEC)
        client.loop_stop()
        client.disconnect()
    except Exception as e:
        print(f"[ERREUR] {e} — retry dans 10s", flush=True)
        time.sleep(10)
SIMEOF
chmod +x /opt/iot-simulator/sensor_simulator.py

cat > /etc/systemd/system/iot-simulator.service << SVCEOF
[Unit]
Description=IoT Temperature Simulator
After=network.target mosquitto.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/iot-simulator/sensor_simulator.py
Environment=MQTT_BROKER=127.0.0.1
Environment=MQTT_PORT=1883
Environment=MQTT_TOPIC=sensors/temperature
Environment=SENSOR_ID=temp-sensor-${INSTANCE_ID}
Environment=MQTT_USER=sensor
Environment=MQTT_PASS=Sensor2024!
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable iot-simulator
systemctl start iot-simulator
systemctl is-active iot-simulator && echo "[OK] Simulateur demarre" || echo "[WARN] Simulateur non demarre"
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWCONF
{"agent":{"run_as_user":"root"},"logs":{"logs_collected":{"files":{"collect_list":[{"file_path":"/var/log/mosquitto/mosquitto.log","log_group_name":"/iot-mqtt/mqtt-gateway","log_stream_name":"${INSTANCE_ID}"},{"file_path":"/var/log/syslog","log_group_name":"/iot-mqtt/system","log_stream_name":"${INSTANCE_ID}-syslog"}]}}}}
CWCONF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s || true
hostnamectl set-hostname "mqtt-gw-${INSTANCE_ID}"
echo "Bootstrap MQTT GW termine - $(date)" >> /var/log/bootstrap.log
USERDATA_MQTT_GW_EOF

cat > /tmp/userdata_snort.sh << 'USERDATA_SNORT_EOF'
#!/bin/bash
set -x
exec > /var/log/bootstrap.log 2>&1
apt-get update -y
apt-get install -y snort amazon-cloudwatch-agent jq curl libpcap-dev net-tools
# SSM Agent
wget -q https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb && rm -f amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
mkdir -p /etc/snort/rules /var/log/snort
chmod 755 /var/log/snort
MAIN_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)
[ -z "$MAIN_IFACE" ] && MAIN_IFACE="ens5"
cat > /etc/snort/snort.conf << SNORTCONF
var HOME_NET 10.1.0.0/16
var EXTERNAL_NET !\$HOME_NET
var MQTT_PORTS [1883,8883]
var RULE_PATH /etc/snort/rules
var LOG_PATH /var/log/snort
config decode_data_link
output alert_syslog: LOG_AUTH LOG_ALERT
output alert_fast: /var/log/snort/alert
include \$RULE_PATH/mqtt.rules
include \$RULE_PATH/local.rules
SNORTCONF
cat > /etc/snort/rules/mqtt.rules << 'RULES'
alert tcp any any -> $HOME_NET [1883,8883] (msg:"MQTT CONNECT Attempt"; content:"|10|"; depth:1; sid:1000001; rev:1;)
alert tcp any any -> $HOME_NET [1883,8883] (msg:"MQTT Brute Force"; threshold: type threshold, track by_src, count 15, seconds 60; sid:1000003; rev:1;)
alert tcp any any -> $HOME_NET [1883,8883] (msg:"MQTT Flood"; threshold: type threshold, track by_src, count 100, seconds 10; sid:1000004; rev:1;)
RULES
cat > /etc/snort/rules/local.rules << 'LOCALRULES'
alert icmp any any -> $HOME_NET any (msg:"ICMP Ping"; itype:8; sid:9000001; rev:1;)
LOCALRULES
touch /etc/snort/unicode.map
cat > /etc/systemd/system/snort.service << SVCEOF
[Unit]
Description=Snort IDS
After=network.target
[Service]
Type=simple
ExecStart=/usr/sbin/snort -D -i ${MAIN_IFACE} -c /etc/snort/snort.conf -l /var/log/snort/ -A full -q
Restart=on-failure
RestartSec=10
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable snort
systemctl start snort || true
cat > /usr/local/bin/snort-watch << 'WATCH'
#!/bin/bash
tail -f /var/log/snort/alert
WATCH
chmod +x /usr/local/bin/snort-watch
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWCONF
{"agent":{"run_as_user":"root"},"logs":{"logs_collected":{"files":{"collect_list":[{"file_path":"/var/log/snort/alert","log_group_name":"/iot-mqtt/snort-alerts","log_stream_name":"${INSTANCE_ID}"},{"file_path":"/var/log/syslog","log_group_name":"/iot-mqtt/system","log_stream_name":"${INSTANCE_ID}-syslog"}]}}}}
CWCONF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s || true
hostnamectl set-hostname "snort-ids-${INSTANCE_ID}"
echo "Bootstrap Snort termine - $(date)" >> /var/log/bootstrap.log
USERDATA_SNORT_EOF

cat > /tmp/userdata_ingestion.sh << 'USERDATA_INGESTION_EOF'
#!/bin/bash
set -x
exec > /var/log/bootstrap.log 2>&1
apt-get update -y
apt-get install -y python3 python3-pip mosquitto mosquitto-clients amazon-cloudwatch-agent jq curl
# SSM Agent
wget -q https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb && rm -f amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
pip3 install paho-mqtt boto3
# Stopper mosquitto avant de reecrire la config (il demarre auto apres install)
systemctl stop mosquitto || true
mkdir -p /var/log/mosquitto /var/lib/mosquitto
chown mosquitto:mosquitto /var/log/mosquitto /var/lib/mosquitto
# Ingestion mosquitto : anonyme OK (reseau prive protege par SG/NACL)
cat > /etc/mosquitto/mosquitto.conf << 'MQTTCONF'
pid_file /run/mosquitto/mosquitto.pid
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log
log_type all

listener 1883 0.0.0.0
allow_anonymous true
max_connections 500
MQTTCONF
rm -f /etc/mosquitto/conf.d/*.conf
systemctl enable mosquitto
systemctl restart mosquitto
sleep 2
systemctl is-active mosquitto && echo "[OK] Mosquitto actif (ingestion)" || echo "[ERREUR] Mosquitto non demarre (ingestion)"
mkdir -p /opt/ingestion /var/log/ingestion
# Script ingest_mqtt.py : se connecte aux 2 brokers GW, ecrit en NDJSON (telemetry.ndjson)
cat > /opt/ingestion/ingest_mqtt.py << 'PYEOF'
#!/usr/bin/env python3
"""
ingest_mqtt.py - Consumer MQTT IoT
  - Decouvre les IPs des GW via SSM Parameter Store
  - Se connecte aux deux brokers en parallele avec le compte 'ingestion'
  - Reçoit des JSON et ecrit en NDJSON (une ligne par message) dans telemetry.ndjson
"""
import paho.mqtt.client as mqtt
import json, os, sys, time, signal, threading, logging
from datetime import datetime, timezone

REGION       = 'us-east-1'
PROJECT      = 'iot-mqtt'
MQTT_USER    = 'ingestion'
MQTT_PASS    = 'Ingestion2024!'
TOPIC        = '#'
NDJSON_FILE  = '/opt/ingestion/telemetry.ndjson'
LOG_FILE     = '/var/log/ingestion/mqtt.log'

os.makedirs(os.path.dirname(NDJSON_FILE), exist_ok=True)
os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
logging.basicConfig(level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[logging.FileHandler(LOG_FILE), logging.StreamHandler(sys.stdout)])
logger = logging.getLogger('ingestion')
file_lock = threading.Lock()

def get_broker_ips():
    """Recupere les IPs des GW depuis SSM Parameter Store avec retry."""
    import boto3
    ssm = boto3.client('ssm', region_name=REGION)
    logger.info("Recherche des IPs GW dans SSM Parameter Store...")
    while True:
        try:
            gw1 = ssm.get_parameter(Name=f'/{PROJECT}/gw1-private-ip')['Parameter']['Value']
            gw2 = ssm.get_parameter(Name=f'/{PROJECT}/gw2-private-ip')['Parameter']['Value']
            logger.info(f"GW1={gw1}, GW2={gw2}")
            return gw1, gw2
        except Exception as e:
            logger.warning(f"SSM non disponible, retry 30s: {e}")
            time.sleep(30)

def make_client(broker_id, broker_host):
    def on_connect(client, userdata, flags, rc):
        codes = {0:"OK",1:"Protocole",2:"ID",3:"Serveur",4:"User/Pass",5:"Refuse"}
        if rc == 0:
            logger.info(f"[{broker_id}] Connecte a {broker_host}:1883")
            client.subscribe(TOPIC, qos=1)
        else:
            logger.error(f"[{broker_id}] Echec connexion: {codes.get(rc,rc)}")

    def on_message(client, userdata, msg):
        try:
            ts = datetime.now(timezone.utc).isoformat()
            try:
                payload_data = json.loads(msg.payload.decode('utf-8'))
            except Exception:
                payload_data = msg.payload.decode('utf-8', errors='replace')
            record = {"ts": ts, "broker": broker_id, "topic": msg.topic, "payload": payload_data}
            line = json.dumps(record, ensure_ascii=False)
            with file_lock:
                with open(NDJSON_FILE, 'a') as f:
                    f.write(line + '\n')
            logger.info(f"[{broker_id}] {msg.topic} -> {str(payload_data)[:80]}")
        except Exception as e:
            logger.error(f"[{broker_id}] on_message error: {e}")

    def on_disconnect(client, userdata, rc):
        if rc != 0:
            logger.warning(f"[{broker_id}] Deconnexion inattendue rc={rc}")

    c = mqtt.Client(client_id=f'ingestion-{broker_id}', clean_session=False)
    c.username_pw_set(MQTT_USER, MQTT_PASS)
    c.on_connect    = on_connect
    c.on_message    = on_message
    c.on_disconnect = on_disconnect
    c.reconnect_delay_set(min_delay=5, max_delay=60)
    return c

def connect_loop(broker_id, broker_host):
    while True:
        try:
            client = make_client(broker_id, broker_host)
            client.connect(broker_host, 1883, keepalive=60)
            client.loop_forever()
        except Exception as e:
            logger.warning(f"[{broker_id}] {e} — retry 10s")
            time.sleep(10)

signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))
logger.info("=== Demarrage service ingestion MQTT (NDJSON) ===")
gw1_ip, gw2_ip = get_broker_ips()

t1 = threading.Thread(target=connect_loop, args=('gw1', gw1_ip), daemon=True)
t2 = threading.Thread(target=connect_loop, args=('gw2', gw2_ip), daemon=True)
t1.start()
t2.start()
logger.info(f"Connecte aux deux brokers : GW1={gw1_ip} | GW2={gw2_ip}")
t1.join()
t2.join()
PYEOF
chmod +x /opt/ingestion/ingest_mqtt.py
cat > /etc/systemd/system/ingestion.service << 'SVCEOF'
[Unit]
Description=IoT MQTT Ingestion Service (NDJSON)
After=network.target mosquitto.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ingestion/ingest_mqtt.py
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload
systemctl enable ingestion
sleep 3
systemctl start ingestion || true
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << CWCONF
{"agent":{"run_as_user":"root"},"logs":{"logs_collected":{"files":{"collect_list":[{"file_path":"/var/log/ingestion/mqtt.log","log_group_name":"/iot-mqtt/ingestion","log_stream_name":"${INSTANCE_ID}"},{"file_path":"/var/log/syslog","log_group_name":"/iot-mqtt/system","log_stream_name":"${INSTANCE_ID}-syslog"}]}}}}
CWCONF
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s || true
hostnamectl set-hostname "ingestion-${INSTANCE_ID}"
echo "Bootstrap Ingestion termine - $(date)" >> /var/log/bootstrap.log
USERDATA_INGESTION_EOF

cat > /tmp/userdata_bastion.sh << 'USERDATA_BASTION_EOF'
#!/bin/bash
set -x
exec > /var/log/bootstrap.log 2>&1
apt-get update -y
apt-get install -y curl wget jq net-tools nmap
# SSM Agent
wget -q https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/debian_amd64/amazon-ssm-agent.deb
dpkg -i amazon-ssm-agent.deb && rm -f amazon-ssm-agent.deb
systemctl enable amazon-ssm-agent && systemctl start amazon-ssm-agent
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
hostnamectl set-hostname "bastion-${INSTANCE_ID}"
echo "Bootstrap Bastion termine - $(date)" >> /var/log/bootstrap.log
USERDATA_BASTION_EOF

chmod +x /tmp/userdata_mqtt_gw.sh /tmp/userdata_snort.sh /tmp/userdata_ingestion.sh /tmp/userdata_bastion.sh

# ── Script simulateur de capteur temperature ──────────────────
cat > /tmp/sensor_simulator.py << 'SIMULATOR_EOF'
#!/usr/bin/env python3
"""
Simulateur de capteur de temperature IoT
Publie des mesures toutes les 5 secondes sur le broker MQTT
Topic : sensors/temperature
"""
import json, math, random, time, signal, sys
import paho.mqtt.client as mqtt

BROKER_HOST  = "localhost"   # Remplace automatiquement par l'IP du GW au deploiement
BROKER_PORT  = 1883
TOPIC        = "sensors/temperature"
SENSOR_ID    = "temp-sensor-01"
INTERVAL_SEC = 5

running = True

def on_connect(client, userdata, flags, rc):
    status = {0:"Connecte", 1:"Mauvais protocole", 2:"ID invalide",
              3:"Serveur indisponible", 4:"Mauvais user/pass", 5:"Non autorise"}
    print(f"[MQTT] {status.get(rc, f'Code {rc}')}")

def on_disconnect(client, userdata, rc):
    if rc != 0:
        print(f"[MQTT] Deconnexion inattendue (code {rc}), reconnexion...")

def generate_temperature():
    t = time.time()
    base = 22.0
    sine = 4.0 * math.sin(2 * math.pi * t / 60)
    noise = random.uniform(-0.5, 0.5)
    return round(base + sine + noise, 2)

def signal_handler(sig, frame):
    global running
    print("\n[INFO] Arret du simulateur...")
    running = False

def main():
    signal.signal(signal.SIGINT,  signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)
    client = mqtt.Client(client_id=f"simulator-{SENSOR_ID}")
    client.on_connect    = on_connect
    client.on_disconnect = on_disconnect
    print(f"[INFO] Connexion au broker {BROKER_HOST}:{BROKER_PORT}...")
    try:
        client.connect(BROKER_HOST, BROKER_PORT, keepalive=60)
    except Exception as e:
        print(f"[ERREUR] Connexion impossible : {e}")
        sys.exit(1)
    client.loop_start()
    print(f"[INFO] Publication sur '{TOPIC}' toutes les {INTERVAL_SEC}s")
    while running:
        temp = generate_temperature()
        payload = json.dumps({
            "sensor_id":    SENSOR_ID,
            "value":        temp,
            "unit":         "celsius",
            "timestamp":    int(time.time()),
            "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        })
        result = client.publish(TOPIC, payload, qos=1)
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            print(f"[PUBLISH] {temp}°C -> {TOPIC}")
        else:
            print(f"[ERREUR] Echec publication (code {result.rc})")
        time.sleep(INTERVAL_SEC)
    client.loop_stop()
    client.disconnect()
    print("[INFO] Simulateur arrete.")

if __name__ == "__main__":
    main()
SIMULATOR_EOF
}


# ─── FONCTIONS UTILITAIRES ───────────────────────────────────
save() { echo "$1=$2" >> "$STATE_FILE"; }

tag() {
  # tag <ResourceType> <ResourceId> <Name>
  aws ec2 create-tags --region "$REGION" \
    --resources "$2" \
    --tags Key=Name,Value="$3" \
           Key=Project,Value="$PROJECT" \
           Key=Environment,Value="$ENV" \
           Key=ManagedBy,Value="aws-cli" 2>/dev/null || true
}

# ─── PRE-REQUIS ──────────────────────────────────────────────
section "VERIFICATION PRE-REQUIS"

for cmd in aws jq curl; do
  command -v "$cmd" &>/dev/null || error "$cmd non installe. Installe-le d'abord."
  log "✓ $cmd disponible"
done

# ─── IDENTITE AWS ────────────────────────────────────────────
section "IDENTITE AWS"

IDENTITY=$(aws sts get-caller-identity --region "$REGION" --output json) \
  || error "Credentials AWS non configures. Lance 'aws configure' ou configure les variables d'environnement."

ACCOUNT=$(echo "$IDENTITY" | jq -r '.Account')
ARN=$(echo "$IDENTITY" | jq -r '.Arn')
USER=$(echo "$IDENTITY" | jq -r '.UserId')

echo -e "  Compte AWS : ${BOLD}$ACCOUNT${NC}"
echo -e "  Identite   : ${BOLD}$ARN${NC}"
echo -e "  Region     : ${BOLD}$REGION${NC}"
echo -e "  Key Pair   : ${BOLD}$KEY_PAIR${NC}"
echo ""

# Verifier que la key pair existe (non bloquant si les perms manquent)
KP_CHECK=$(aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_PAIR" \
  --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || echo "")
if [[ -z "$KP_CHECK" || "$KP_CHECK" == "None" ]]; then
  # Tenter de lister toutes les key pairs disponibles
  AVAILABLE_KP=$(aws ec2 describe-key-pairs --region "$REGION" \
    --query 'KeyPairs[*].KeyName' --output text 2>/dev/null || echo "")
  if [[ -n "$AVAILABLE_KP" ]]; then
    warn "Key pair '$KEY_PAIR' introuvable. Key pairs disponibles : $AVAILABLE_KP"
    warn "Relance avec : KEY_PAIR=<nom> bash deploy.sh"
    exit 1
  else
    warn "Impossible de verifier la key pair (permissions insuffisantes) — on continue avec '$KEY_PAIR'"
  fi
fi

read -r -p "$(echo -e "${YELLOW}⚠️  Confirmer le deploiement sur ce compte ? (yes/no) :${NC} ")" CONFIRM
[[ "$CONFIRM" == "yes" ]] || { log "Annule."; exit 0; }

# Ecrire les scripts userdata dans /tmp
write_userdata_scripts
log "Scripts userdata ecrits dans /tmp"

# Reinitialiser le state file
> "$STATE_FILE"
save "ACCOUNT" "$ACCOUNT"
save "REGION" "$REGION"
save "DEPLOY_TIME" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ─── AMI Ubuntu 22.04 LTS ────────────────────────────────────
section "RECHERCHE AMI"

# 1er essai : SSM Parameter Store (ne necessite pas ec2:DescribeImages)
AMI_ID=$(aws ssm get-parameter \
  --region "$REGION" \
  --name "/aws/service/canonical/ubuntu/server/22.04/stable/current/amd64/hvm/ebs-gp2/ami-id" \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")

# 2eme essai : DescribeImages si SSM echoue
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  AMI_ID=$(aws ec2 describe-images \
    --region "$REGION" \
    --owners 099720109477 \
    --filters \
      "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
      "Name=state,Values=available" \
      "Name=architecture,Values=x86_64" \
    --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
    --output text 2>/dev/null || echo "")
fi

# Fallback : AMI Ubuntu 22.04 LTS us-east-1 connue (mise a jour regulierement)
if [[ -z "$AMI_ID" || "$AMI_ID" == "None" ]]; then
  AMI_ID="ami-0261755bbcb8c4a84"
  warn "AMI non trouvee via API — utilisation AMI hardcodee : $AMI_ID"
fi

[[ -z "$AMI_ID" ]] && error "AMI Ubuntu 22.04 introuvable"
save "AMI_ID" "$AMI_ID"
log "AMI Ubuntu 22.04 LTS : $AMI_ID"

# ════════════════════════════════════════════════════════════
section "1/12 - VPC"
# ════════════════════════════════════════════════════════════

VPC_ID=$(aws ec2 create-vpc \
  --region "$REGION" \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications "ResourceType=vpc,Tags=[
    {Key=Name,Value=${PROJECT}-vpc},
    {Key=Project,Value=${PROJECT}},
    {Key=Environment,Value=${ENV}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'Vpc.VpcId' --output text)

aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-hostnames
aws ec2 modify-vpc-attribute --region "$REGION" --vpc-id "$VPC_ID" --enable-dns-support

save "VPC_ID" "$VPC_ID"
log "VPC cree : $VPC_ID ($VPC_CIDR)"

# ════════════════════════════════════════════════════════════
section "2/12 - SUBNETS"
# ════════════════════════════════════════════════════════════

SUBNET_DMZ=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block "$DMZ_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-subnet-dmz},
    {Key=Project,Value=${PROJECT}},
    {Key=Type,Value=public},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'Subnet.SubnetId' --output text)
save "SUBNET_DMZ" "$SUBNET_DMZ"
log "Subnet DMZ    : $SUBNET_DMZ ($DMZ_CIDR)"

# Auto-assign public IP pour les instances dans le subnet DMZ
aws ec2 modify-subnet-attribute \
  --region "$REGION" \
  --subnet-id "$SUBNET_DMZ" \
  --map-public-ip-on-launch > /dev/null
log "Auto-assign public IP active sur subnet DMZ"

# Second subnet DMZ dans us-east-1b pour GW2 (haute disponibilite multi-AZ)
SUBNET_DMZ_B=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block "$DMZ_CIDR_B" \
  --availability-zone "$AZ_B" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-subnet-dmz-b},
    {Key=Project,Value=${PROJECT}},
    {Key=Type,Value=public},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'Subnet.SubnetId' --output text)
aws ec2 modify-subnet-attribute --region "$REGION" --subnet-id "$SUBNET_DMZ_B" \
  --map-public-ip-on-launch > /dev/null
aws ec2 associate-route-table --region "$REGION" \
  --route-table-id "$RT_DMZ" --subnet-id "$SUBNET_DMZ_B" > /dev/null
save "SUBNET_DMZ_B" "$SUBNET_DMZ_B"
log "Subnet DMZ-B  : $SUBNET_DMZ_B ($DMZ_CIDR_B) [AZ: $AZ_B]"

SUBNET_PRIVATE=$(aws ec2 create-subnet \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --cidr-block "$PRIVATE_CIDR" \
  --availability-zone "$AZ" \
  --tag-specifications "ResourceType=subnet,Tags=[
    {Key=Name,Value=${PROJECT}-subnet-private},
    {Key=Project,Value=${PROJECT}},
    {Key=Type,Value=private},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'Subnet.SubnetId' --output text)
save "SUBNET_PRIVATE" "$SUBNET_PRIVATE"
log "Subnet Private: $SUBNET_PRIVATE ($PRIVATE_CIDR)"

# ════════════════════════════════════════════════════════════
section "3/12 - INTERNET GATEWAY"
# ════════════════════════════════════════════════════════════

IGW_ID=$(aws ec2 create-internet-gateway \
  --region "$REGION" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[
    {Key=Name,Value=${PROJECT}-igw},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --internet-gateway-id "$IGW_ID"

save "IGW_ID" "$IGW_ID"
log "Internet Gateway : $IGW_ID (attache au VPC)"

# ════════════════════════════════════════════════════════════
section "4/12 - NAT GATEWAY"
# ════════════════════════════════════════════════════════════

EIP_ALLOC=$(aws ec2 allocate-address \
  --region "$REGION" \
  --domain vpc \
  --query 'AllocationId' --output text)
aws ec2 create-tags --region "$REGION" --resources "$EIP_ALLOC" \
  --tags Key=Name,Value="${PROJECT}-nat-eip" Key=Project,Value="$PROJECT" Key=ManagedBy,Value=aws-cli
save "EIP_ALLOC" "$EIP_ALLOC"
log "Elastic IP allouee : $EIP_ALLOC"

NAT_GW=$(aws ec2 create-nat-gateway \
  --region "$REGION" \
  --subnet-id "$SUBNET_DMZ" \
  --allocation-id "$EIP_ALLOC" \
  --tag-specifications "ResourceType=natgateway,Tags=[
    {Key=Name,Value=${PROJECT}-nat-gw},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'NatGateway.NatGatewayId' --output text)
save "NAT_GW" "$NAT_GW"

log "NAT Gateway en creation : $NAT_GW"
log "Attente disponibilite NAT Gateway (2-3 minutes)..."
aws ec2 wait nat-gateway-available --region "$REGION" --nat-gateway-ids "$NAT_GW"
log "NAT Gateway disponible"

# ════════════════════════════════════════════════════════════
section "5/12 - ROUTE TABLES"
# ════════════════════════════════════════════════════════════

# Route table DMZ -> IGW
RT_DMZ=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=${PROJECT}-rt-dmz},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region "$REGION" --route-table-id "$RT_DMZ" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW_ID" > /dev/null
aws ec2 associate-route-table --region "$REGION" \
  --route-table-id "$RT_DMZ" --subnet-id "$SUBNET_DMZ" > /dev/null
save "RT_DMZ" "$RT_DMZ"
log "Route table DMZ : $RT_DMZ (0.0.0.0/0 -> IGW)"

# Route table Private -> NAT GW
RT_PRIVATE=$(aws ec2 create-route-table \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=route-table,Tags=[
    {Key=Name,Value=${PROJECT}-rt-private},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --region "$REGION" --route-table-id "$RT_PRIVATE" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT_GW" > /dev/null
aws ec2 associate-route-table --region "$REGION" \
  --route-table-id "$RT_PRIVATE" --subnet-id "$SUBNET_PRIVATE" > /dev/null
save "RT_PRIVATE" "$RT_PRIVATE"
log "Route table Private : $RT_PRIVATE (0.0.0.0/0 -> NAT GW)"

# ════════════════════════════════════════════════════════════
section "6/12 - SECURITY GROUPS"
# ════════════════════════════════════════════════════════════

# SG MQTT Gateways
SG_MQTT_GW=$(aws ec2 create-security-group \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-mqtt-gw" \
  --description "MQTT Gateways - ports 1883/8883" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-sg-mqtt-gw},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'GroupId' --output text)

# MQTT TLS public (via NLB)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_MQTT_GW" \
  --protocol tcp --port 8883 --cidr 0.0.0.0/0 > /dev/null
# MQTT interne depuis subnet prive
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_MQTT_GW" \
  --protocol tcp --port 1883 --cidr "$PRIVATE_CIDR" > /dev/null
# MQTT interne depuis DMZ (entre gateways)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_MQTT_GW" \
  --protocol tcp --port 1883 --cidr "$DMZ_CIDR" > /dev/null
# ICMP VPC
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_MQTT_GW" \
  --protocol icmp --port -1 --cidr "$VPC_CIDR" > /dev/null

save "SG_MQTT_GW" "$SG_MQTT_GW"
log "SG MQTT GW : $SG_MQTT_GW"

# SG Snort IDS
SG_SNORT=$(aws ec2 create-security-group \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-snort" \
  --description "Snort IDS - Traffic Mirroring VXLAN" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-sg-snort},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'GroupId' --output text)

# VXLAN UDP 4789 pour Traffic Mirroring (depuis DMZ)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_SNORT" \
  --protocol udp --port 4789 --cidr "$VPC_CIDR" > /dev/null
# ICMP VPC
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_SNORT" \
  --protocol icmp --port -1 --cidr "$VPC_CIDR" > /dev/null

save "SG_SNORT" "$SG_SNORT"
log "SG Snort IDS : $SG_SNORT"

# SG Bastion (acces SSH admin depuis internet)
SG_BASTION=$(aws ec2 create-security-group \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-bastion" \
  --description "Bastion SSH - acces admin" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-sg-bastion},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_BASTION" \
  --protocol tcp --port 22 --cidr 0.0.0.0/0 > /dev/null
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_BASTION" \
  --protocol icmp --port -1 --cidr "$VPC_CIDR" > /dev/null
save "SG_BASTION" "$SG_BASTION"
log "SG Bastion   : $SG_BASTION"

# SG Ingestion (prive)
SG_INGESTION=$(aws ec2 create-security-group \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --group-name "${PROJECT}-sg-ingestion" \
  --description "Ingestion backend - MQTT depuis DMZ, SSH depuis bastion" \
  --tag-specifications "ResourceType=security-group,Tags=[
    {Key=Name,Value=${PROJECT}-sg-ingestion},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'GroupId' --output text)

# MQTT 1883 depuis DMZ seulement
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_INGESTION" \
  --protocol tcp --port 1883 --cidr "$DMZ_CIDR" > /dev/null
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_INGESTION" \
  --protocol tcp --port 1883 --cidr "$DMZ_CIDR_B" > /dev/null
# SSH uniquement depuis le bastion
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_INGESTION" \
  --protocol tcp --port 22 --source-group "$SG_BASTION" > /dev/null
# ICMP VPC
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_INGESTION" \
  --protocol icmp --port -1 --cidr "$VPC_CIDR" > /dev/null

save "SG_INGESTION" "$SG_INGESTION"
log "SG Ingestion : $SG_INGESTION"

# ════════════════════════════════════════════════════════════
section "7/12 - NACL"
# ════════════════════════════════════════════════════════════

create_nacl_rule() {
  local nacl_id="$1" rule_num="$2" protocol="$3" action="$4"
  local direction="$5" cidr="$6" from_port="$7" to_port="$8"
  local extra_args=""
  [[ "$from_port" != "-" ]] && extra_args="--port-range From=${from_port},To=${to_port}"
  aws ec2 create-network-acl-entry --region "$REGION" \
    --network-acl-id "$nacl_id" \
    --rule-number "$rule_num" \
    --protocol "$protocol" \
    --rule-action "$action" \
    --"$direction" \
    --cidr-block "$cidr" \
    $extra_args > /dev/null
}

# NACL DMZ
NACL_DMZ=$(aws ec2 create-network-acl \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=network-acl,Tags=[
    {Key=Name,Value=${PROJECT}-nacl-dmz},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'NetworkAcl.NetworkAclId' --output text)

# Inbound DMZ
create_nacl_rule "$NACL_DMZ" 90  tcp allow ingress 0.0.0.0/0 22 22         # SSH admin
create_nacl_rule "$NACL_DMZ" 100 tcp allow ingress 0.0.0.0/0 8883 8883   # MQTT TLS public
create_nacl_rule "$NACL_DMZ" 105 tcp allow ingress 0.0.0.0/0 1883 1883   # MQTT plaintext (Android/demo)
create_nacl_rule "$NACL_DMZ" 110 tcp allow ingress 0.0.0.0/0 1024 65535  # Ephemeral
create_nacl_rule "$NACL_DMZ" 120 tcp allow ingress "$PRIVATE_CIDR" 1883 1883  # MQTT depuis prive
create_nacl_rule "$NACL_DMZ" 130 udp allow ingress "$VPC_CIDR" 4789 4789  # VXLAN mirroring
create_nacl_rule "$NACL_DMZ" 900 "-1" deny  ingress 0.0.0.0/0 - -        # Deny tout reste
# Outbound DMZ
create_nacl_rule "$NACL_DMZ" 100 tcp allow egress 0.0.0.0/0 1024 65535   # Ephemeral
create_nacl_rule "$NACL_DMZ" 110 tcp allow egress 0.0.0.0/0 443 443       # HTTPS (SSM, updates)
create_nacl_rule "$NACL_DMZ" 115 tcp allow egress 0.0.0.0/0 80 80         # HTTP (apt-get)
create_nacl_rule "$NACL_DMZ" 120 tcp allow egress "$PRIVATE_CIDR" 1883 1883  # MQTT vers prive
create_nacl_rule "$NACL_DMZ" 900 "-1" deny  egress 0.0.0.0/0 - -          # Deny tout reste

# Remplacer NACL du subnet DMZ
ASSOC_DMZ=$(aws ec2 describe-network-acls --region "$REGION" \
  --filters "Name=association.subnet-id,Values=$SUBNET_DMZ" \
  --query 'NetworkAcls[0].Associations[?SubnetId==`'"$SUBNET_DMZ"'`].NetworkAclAssociationId' \
  --output text)
aws ec2 replace-network-acl-association --region "$REGION" \
  --association-id "$ASSOC_DMZ" --network-acl-id "$NACL_DMZ" > /dev/null
save "NACL_DMZ" "$NACL_DMZ"
log "NACL DMZ : $NACL_DMZ"

# NACL Private
NACL_PRIVATE=$(aws ec2 create-network-acl \
  --region "$REGION" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=network-acl,Tags=[
    {Key=Name,Value=${PROJECT}-nacl-private},
    {Key=Project,Value=${PROJECT}},
    {Key=ManagedBy,Value=aws-cli}
  ]" \
  --query 'NetworkAcl.NetworkAclId' --output text)

# Inbound Private
create_nacl_rule "$NACL_PRIVATE" 100 tcp allow ingress "$DMZ_CIDR" 1883 1883   # MQTT depuis DMZ
create_nacl_rule "$NACL_PRIVATE" 110 tcp allow ingress 0.0.0.0/0 1024 65535   # Ephemeral (retours NAT)
create_nacl_rule "$NACL_PRIVATE" 900 "-1" deny  ingress 0.0.0.0/0 - -         # Deny tout reste
# Outbound Private
create_nacl_rule "$NACL_PRIVATE" 100 tcp allow egress 0.0.0.0/0 443 443        # HTTPS via NAT (SSM, updates)
create_nacl_rule "$NACL_PRIVATE" 110 tcp allow egress 0.0.0.0/0 80 80          # HTTP via NAT
create_nacl_rule "$NACL_PRIVATE" 120 tcp allow egress 0.0.0.0/0 1024 65535     # Ephemeral
create_nacl_rule "$NACL_PRIVATE" 900 "-1" deny  egress 0.0.0.0/0 - -           # Deny tout reste

ASSOC_PRIVATE=$(aws ec2 describe-network-acls --region "$REGION" \
  --filters "Name=association.subnet-id,Values=$SUBNET_PRIVATE" \
  --query 'NetworkAcls[0].Associations[?SubnetId==`'"$SUBNET_PRIVATE"'`].NetworkAclAssociationId' \
  --output text)
aws ec2 replace-network-acl-association --region "$REGION" \
  --association-id "$ASSOC_PRIVATE" --network-acl-id "$NACL_PRIVATE" > /dev/null
save "NACL_PRIVATE" "$NACL_PRIVATE"
log "NACL Private : $NACL_PRIVATE"

# ════════════════════════════════════════════════════════════
section "8/12 - IAM ROLE (SSM + CloudWatch)"
# ════════════════════════════════════════════════════════════

ROLE_NAME="${PROJECT}-ec2-role"
PROFILE_NAME="${PROJECT}-ec2-profile"

# Trust policy
cat > /tmp/trust-ec2.json << 'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "ec2.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}
TRUST

# Creer le role (ignore si existe)
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file:///tmp/trust-ec2.json \
  --tags Key=Project,Value="$PROJECT" Key=ManagedBy,Value=aws-cli \
  2>/dev/null && log "Role IAM cree : $ROLE_NAME" || warn "Role $ROLE_NAME existe deja, on continue"

# Attacher les policies
for POLICY in \
  "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore" \
  "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"; do
  aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY" 2>/dev/null || true
done

# Instance profile
aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" 2>/dev/null \
  && log "Instance profile cree : $PROFILE_NAME" \
  || warn "Instance profile $PROFILE_NAME existe deja"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME" 2>/dev/null || true

save "IAM_ROLE" "$ROLE_NAME"
save "IAM_PROFILE" "$PROFILE_NAME"
log "Attente propagation IAM (20s)..."
sleep 20

# ════════════════════════════════════════════════════════════
section "9/12 - INSTANCES EC2"
# ════════════════════════════════════════════════════════════

EBS_MAPPING='[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","Encrypted":true,"DeleteOnTermination":true}}]'

launch_instance() {
  local name="$1" subnet="$2" sg="$3" type="$4" userdata="$5" role_tag="$6"
  aws ec2 run-instances \
    --region "$REGION" \
    --image-id "$AMI_ID" \
    --instance-type "$type" \
    --subnet-id "$subnet" \
    --security-group-ids "$sg" \
    --iam-instance-profile Name="$PROFILE_NAME" \
    --key-name "$KEY_PAIR" \
    --user-data "file://${SCRIPT_DIR}/${userdata}" \
    --block-device-mappings "$EBS_MAPPING" \
    --tag-specifications \
      "ResourceType=instance,Tags=[
        {Key=Name,Value=${PROJECT}-${name}},
        {Key=Project,Value=${PROJECT}},
        {Key=Role,Value=${role_tag}},
        {Key=Environment,Value=${ENV}},
        {Key=ManagedBy,Value=aws-cli}
      ]" \
      "ResourceType=volume,Tags=[
        {Key=Name,Value=${PROJECT}-${name}-vol},
        {Key=Project,Value=${PROJECT}},
        {Key=ManagedBy,Value=aws-cli}
      ]" \
    --query 'Instances[0].InstanceId' --output text
}

log "Lancement mqtt-gw1..."
INST_GW1=$(launch_instance "mqtt-gw1" "$SUBNET_DMZ" "$SG_MQTT_GW" "$INSTANCE_TYPE_GW" \
  "userdata_mqtt_gw.sh" "mqtt-gateway")
save "INST_GW1" "$INST_GW1"
log "mqtt-gw1 : $INST_GW1"

log "Lancement mqtt-gw2... (AZ: $AZ_B pour haute disponibilite)"
INST_GW2=$(launch_instance "mqtt-gw2" "$SUBNET_DMZ_B" "$SG_MQTT_GW" "$INSTANCE_TYPE_GW" \
  "userdata_mqtt_gw.sh" "mqtt-gateway")
save "INST_GW2" "$INST_GW2"
log "mqtt-gw2 : $INST_GW2"

log "Lancement bastion (DMZ - SSH admin)..."
INST_BASTION=$(launch_instance "bastion" "$SUBNET_DMZ" "$SG_BASTION" "$INSTANCE_TYPE_BASTION" \
  "userdata_bastion.sh" "bastion")
save "INST_BASTION" "$INST_BASTION"
log "bastion : $INST_BASTION"

log "Lancement snort-ids..."
INST_SNORT=$(launch_instance "snort-ids" "$SUBNET_DMZ" "$SG_SNORT" "$INSTANCE_TYPE_SNORT" \
  "userdata_snort.sh" "ids")
save "INST_SNORT" "$INST_SNORT"
log "snort-ids : $INST_SNORT"

log "Lancement ingestion-analyse..."
INST_INGESTION=$(launch_instance "ingestion" "$SUBNET_PRIVATE" "$SG_INGESTION" "$INSTANCE_TYPE_INGESTION" \
  "userdata_ingestion.sh" "ingestion")
save "INST_INGESTION" "$INST_INGESTION"
log "ingestion : $INST_INGESTION"

log "Attente etat 'running' pour toutes les instances..."
aws ec2 wait instance-running --region "$REGION" \
  --instance-ids "$INST_GW1" "$INST_GW2" "$INST_SNORT" "$INST_INGESTION" "$INST_BASTION"
log "Toutes les instances sont en etat running"

# Recuperer les IPs privees
get_private_ip() {
  aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text
}
get_public_ip() {
  aws ec2 describe-instances --region "$REGION" --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

IP_GW1=$(get_private_ip "$INST_GW1")
IP_GW2=$(get_private_ip "$INST_GW2")
IP_SNORT=$(get_private_ip "$INST_SNORT")
IP_INGESTION=$(get_private_ip "$INST_INGESTION")
IP_BASTION_PUB=$(get_public_ip "$INST_BASTION")

save "IP_GW1" "$IP_GW1"
save "IP_GW2" "$IP_GW2"
save "IP_SNORT" "$IP_SNORT"
save "IP_INGESTION" "$IP_INGESTION"
save "IP_BASTION_PUB" "$IP_BASTION_PUB"

log "IPs privees : GW1=$IP_GW1 | GW2=$IP_GW2 | Snort=$IP_SNORT | Ingestion=$IP_INGESTION"
log "Bastion IP publique : $IP_BASTION_PUB"

# Publier les IPs des GW dans SSM Parameter Store
# Le subscriber ingestion les recupere au demarrage pour se connecter aux 2 brokers
log "Publication IPs GW dans SSM Parameter Store..."
aws ssm put-parameter --region "$REGION" \
  --name "/${PROJECT}/gw1-private-ip" --value "$IP_GW1" \
  --type String --overwrite > /dev/null
aws ssm put-parameter --region "$REGION" \
  --name "/${PROJECT}/gw2-private-ip" --value "$IP_GW2" \
  --type String --overwrite > /dev/null
log "SSM params publies : /${PROJECT}/gw1-private-ip=$IP_GW1 | /${PROJECT}/gw2-private-ip=$IP_GW2"

# ════════════════════════════════════════════════════════════
section "10/12 - NETWORK LOAD BALANCER"
# ════════════════════════════════════════════════════════════

NLB_ARN=$(aws elbv2 create-load-balancer \
  --region "$REGION" \
  --name "${PROJECT}-nlb" \
  --type network \
  --scheme internet-facing \
  --subnets "$SUBNET_DMZ" "$SUBNET_DMZ_B" \
  --tags \
    Key=Name,Value="${PROJECT}-nlb" \
    Key=Project,Value="$PROJECT" \
    Key=Environment,Value="$ENV" \
    Key=ManagedBy,Value=aws-cli \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

NLB_DNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
  --load-balancer-arns "$NLB_ARN" \
  --query 'LoadBalancers[0].DNSName' --output text)

save "NLB_ARN" "$NLB_ARN"
save "NLB_DNS" "$NLB_DNS"
log "NLB cree : $NLB_DNS"

# Target Group TCP:8883
TG_ARN=$(aws elbv2 create-target-group \
  --region "$REGION" \
  --name "${PROJECT}-tg-mqtt" \
  --protocol TCP \
  --port 8883 \
  --vpc-id "$VPC_ID" \
  --health-check-protocol TCP \
  --health-check-port 8883 \
  --health-check-interval-seconds 30 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --tags \
    Key=Name,Value="${PROJECT}-tg-mqtt" \
    Key=Project,Value="$PROJECT" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
save "TG_ARN" "$TG_ARN"

# Enregistrer les 2 gateways dans le target group
aws elbv2 register-targets --region "$REGION" \
  --target-group-arn "$TG_ARN" \
  --targets Id="$INST_GW1",Port=8883 Id="$INST_GW2",Port=8883
log "GW1 et GW2 enregistrees dans le Target Group"

# Listener TCP:8883
LISTENER_ARN=$(aws elbv2 create-listener \
  --region "$REGION" \
  --load-balancer-arn "$NLB_ARN" \
  --protocol TCP \
  --port 8883 \
  --default-actions Type=forward,TargetGroupArn="$TG_ARN" \
  --tags Key=Name,Value="${PROJECT}-listener-mqtt" Key=Project,Value="$PROJECT" \
  --query 'Listeners[0].ListenerArn' --output text)
save "LISTENER_ARN" "$LISTENER_ARN"
log "Listener TCP:8883 cree"

# ════════════════════════════════════════════════════════════
section "11/12 - VPC TRAFFIC MIRRORING (Snort IDS)"
# ════════════════════════════════════════════════════════════

# ENI de l'instance Snort (cible du miroir)
ENI_SNORT=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INST_SNORT" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
save "ENI_SNORT" "$ENI_SNORT"

# Mirror Target
MIRROR_TARGET=$(aws ec2 create-traffic-mirror-target \
  --region "$REGION" \
  --network-interface-id "$ENI_SNORT" \
  --description "Snort IDS - destination du trafic miroire" \
  --query 'TrafficMirrorTarget.TrafficMirrorTargetId' --output text)
save "MIRROR_TARGET" "$MIRROR_TARGET"
log "Mirror Target cree : $MIRROR_TARGET"

# Mirror Filter
MIRROR_FILTER=$(aws ec2 create-traffic-mirror-filter \
  --region "$REGION" \
  --description "Filtre trafic MQTT vers Snort" \
  --query 'TrafficMirrorFilter.TrafficMirrorFilterId' --output text)
save "MIRROR_FILTER" "$MIRROR_FILTER"

# Regles du filtre - tout le trafic TCP (inclut MQTT 1883/8883)
aws ec2 create-traffic-mirror-filter-rule \
  --region "$REGION" \
  --traffic-mirror-filter-id "$MIRROR_FILTER" \
  --traffic-direction ingress \
  --rule-number 100 \
  --rule-action accept \
  --protocol 6 \
  --destination-cidr-block 0.0.0.0/0 \
  --source-cidr-block 0.0.0.0/0 > /dev/null

aws ec2 create-traffic-mirror-filter-rule \
  --region "$REGION" \
  --traffic-mirror-filter-id "$MIRROR_FILTER" \
  --traffic-direction egress \
  --rule-number 100 \
  --rule-action accept \
  --protocol 6 \
  --destination-cidr-block 0.0.0.0/0 \
  --source-cidr-block 0.0.0.0/0 > /dev/null

log "Regles Mirror Filter configurees"

# ENIs des gateways MQTT
ENI_GW1=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INST_GW1" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
ENI_GW2=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INST_GW2" \
  --query 'Reservations[0].Instances[0].NetworkInterfaces[0].NetworkInterfaceId' --output text)
save "ENI_GW1" "$ENI_GW1"
save "ENI_GW2" "$ENI_GW2"

# Session miroir GW1 -> Snort
SESSION_GW1=$(aws ec2 create-traffic-mirror-session \
  --region "$REGION" \
  --network-interface-id "$ENI_GW1" \
  --traffic-mirror-target-id "$MIRROR_TARGET" \
  --traffic-mirror-filter-id "$MIRROR_FILTER" \
  --session-number 1 \
  --description "Mirror mqtt-gw1 vers snort-ids" \
  --query 'TrafficMirrorSession.TrafficMirrorSessionId' --output text)
save "SESSION_GW1" "$SESSION_GW1"

# Session miroir GW2 -> Snort
SESSION_GW2=$(aws ec2 create-traffic-mirror-session \
  --region "$REGION" \
  --network-interface-id "$ENI_GW2" \
  --traffic-mirror-target-id "$MIRROR_TARGET" \
  --traffic-mirror-filter-id "$MIRROR_FILTER" \
  --session-number 2 \
  --description "Mirror mqtt-gw2 vers snort-ids" \
  --query 'TrafficMirrorSession.TrafficMirrorSessionId' --output text)
save "SESSION_GW2" "$SESSION_GW2"
log "Traffic Mirroring actif : GW1($ENI_GW1) + GW2($ENI_GW2) -> Snort($ENI_SNORT)"

# ════════════════════════════════════════════════════════════
section "12/14 - CLOUDWATCH LOGS + ALARMES"
# ════════════════════════════════════════════════════════════

for LG in \
  "/iot-mqtt/mqtt-gateway" \
  "/iot-mqtt/snort-alerts" \
  "/iot-mqtt/ingestion" \
  "/iot-mqtt/ingestion-broker" \
  "/iot-mqtt/system" \
  "/iot-mqtt/bootstrap"; do
  aws logs create-log-group --region "$REGION" --log-group-name "$LG" 2>/dev/null || true
  aws logs put-retention-policy --region "$REGION" \
    --log-group-name "$LG" --retention-in-days 30
done
log "Log Groups CloudWatch crees (retention 30 jours)"

# SNS Topic pour alertes
SNS_ARN=$(aws sns create-topic \
  --region "$REGION" \
  --name "${PROJECT}-alerts" \
  --tags Key=Project,Value="$PROJECT" Key=ManagedBy,Value=aws-cli \
  --query 'TopicArn' --output text)
save "SNS_ARN" "$SNS_ARN"
log "SNS Topic : $SNS_ARN"
warn "Pour recevoir les alertes email : aws sns subscribe --topic-arn $SNS_ARN --protocol email --notification-endpoint TON@EMAIL.COM --region $REGION"

# Alarmes CloudWatch
create_alarm() {
  local name="$1" desc="$2" metric="$3" inst="$4" threshold="$5"
  aws cloudwatch put-metric-alarm \
    --region "$REGION" \
    --alarm-name "${PROJECT}-${name}-${inst}" \
    --alarm-description "$desc" \
    --metric-name "$metric" \
    --namespace AWS/EC2 \
    --statistic Average \
    --dimensions Name=InstanceId,Value="$inst" \
    --period 300 \
    --evaluation-periods 2 \
    --threshold "$threshold" \
    --comparison-operator GreaterThanThreshold \
    --alarm-actions "$SNS_ARN" \
    --ok-actions "$SNS_ARN" 2>/dev/null || true
}

for INST in "$INST_GW1" "$INST_GW2"; do
  create_alarm "cpu-high"  "CPU > 80% MQTT GW"   "CPUUtilization"   "$INST" 80
  create_alarm "status"    "Status Check Failed"  "StatusCheckFailed" "$INST" 1
done
create_alarm "cpu-high" "CPU > 80% Snort"     "CPUUtilization"    "$INST_SNORT"     80
create_alarm "cpu-high" "CPU > 70% Ingestion" "CPUUtilization"    "$INST_INGESTION" 70
log "Alarmes CloudWatch configurees"

# ════════════════════════════════════════════════════════════
section "13/14 - MQTT PORT 1883 (DEMO / APP ANDROID)"
# ════════════════════════════════════════════════════════════

# ── Règle SG GW : ouvrir port 1883 depuis internet ───────────────────────────
EXISTING_1883=$(aws ec2 describe-security-groups \
  --region "$REGION" --group-ids "$SG_MQTT_GW" \
  --query "SecurityGroups[0].IpPermissions[?FromPort==\`1883\`].IpRanges[?CidrIp=='0.0.0.0/0'].CidrIp" \
  --output text 2>/dev/null || true)
if [[ -z "$EXISTING_1883" ]]; then
  aws ec2 authorize-security-group-ingress \
    --region "$REGION" --group-id "$SG_MQTT_GW" \
    --protocol tcp --port 1883 --cidr 0.0.0.0/0 > /dev/null
  log "Port 1883 ouvert depuis internet sur le SG GW ($SG_MQTT_GW)"
else
  log "Port 1883 deja ouvert depuis internet sur le SG GW"
fi

# ── NLB : Target Group port 1883 ─────────────────────────────────────────────
TG_1883=$(aws elbv2 create-target-group \
  --region "$REGION" \
  --name "${PROJECT}-tg-mqtt-1883" \
  --protocol TCP --port 1883 \
  --vpc-id "$VPC_ID" \
  --health-check-protocol TCP \
  --health-check-port 1883 \
  --target-type instance \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
save "TG_1883" "$TG_1883"

aws elbv2 register-targets \
  --region "$REGION" \
  --target-group-arn "$TG_1883" \
  --targets Id="$INST_GW1" Id="$INST_GW2" > /dev/null
log "Target Group 1883 cree : $TG_1883"

# ── NLB : Listener port 1883 ─────────────────────────────────────────────────
LISTENER_1883=$(aws elbv2 create-listener \
  --region "$REGION" \
  --load-balancer-arn "$NLB_ARN" \
  --protocol TCP --port 1883 \
  --default-actions Type=forward,TargetGroupArn="$TG_1883" \
  --query 'Listeners[0].ListenerArn' --output text)
save "LISTENER_1883" "$LISTENER_1883"
log "Listener NLB port 1883 cree : $LISTENER_1883"

# ════════════════════════════════════════════════════════════
section "14/14 - SIMULATEUR CAPTEUR TEMPERATURE (IoT)"
# ════════════════════════════════════════════════════════════

# Le simulateur est embarque directement dans le userdata des GW (service systemd iot-simulator).
# Il demarre automatiquement apres boot, sans dependance SSM.
log "Simulateur de temperature : service systemd integre dans GW1 ($INST_GW1) et GW2 ($INST_GW2)"
log "Verifier apres boot (~3 min) :"
log "  aws ssm start-session --target $INST_GW1 --region $REGION"
log "  sudo systemctl status iot-simulator"

# ════════════════════════════════════════════════════════════
section "RECAPITULATIF FINAL"
# ════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         DEPLOIEMENT IOT MQTT - TERMINE                  ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}VPC${NC}              : $VPC_ID ($VPC_CIDR)"
echo -e "  ${BOLD}Subnet DMZ-A${NC}     : $SUBNET_DMZ   ($DMZ_CIDR)   [AZ: $AZ]"
echo -e "  ${BOLD}Subnet DMZ-B${NC}     : $SUBNET_DMZ_B ($DMZ_CIDR_B) [AZ: $AZ_B]"
echo -e "  ${BOLD}Subnet Private${NC}   : $SUBNET_PRIVATE ($PRIVATE_CIDR)"
echo ""
echo -e "  ${BOLD}mqtt-gw1${NC}         : $INST_GW1 | IP: $IP_GW1  [AZ: $AZ]"
echo -e "  ${BOLD}mqtt-gw2${NC}         : $INST_GW2 | IP: $IP_GW2  [AZ: $AZ_B]"
echo -e "  ${BOLD}snort-ids${NC}        : $INST_SNORT | IP: $IP_SNORT"
echo -e "  ${BOLD}ingestion${NC}        : $INST_INGESTION | IP: $IP_INGESTION"
echo -e "  ${BOLD}bastion${NC}          : $INST_BASTION | IP publique: $IP_BASTION_PUB"
echo ""
echo -e "  ${BOLD}NLB DNS${NC}          : $NLB_DNS"
echo -e "  ${BOLD}MQTT 8883 (TLS)${NC}  : $NLB_DNS:8883"
echo -e "  ${BOLD}MQTT 1883${NC}        : $NLB_DNS:1883"
echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║  CREDENTIALS MQTT                                       ║${NC}"
echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${YELLOW}║  sensor    / $MQTT_PASS_SENSOR   (publish sensors/#)   ║${NC}"
echo -e "${BOLD}${YELLOW}║  ingestion / $MQTT_PASS_INGESTION  (subscribe #)       ║${NC}"
echo -e "${BOLD}${YELLOW}║  dashboard / $MQTT_PASS_DASHBOARD  (subscribe sensors/#)║${NC}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BOLD}${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${YELLOW}║  APP ANDROID / WEB DASHBOARD                            ║${NC}"
echo -e "${BOLD}${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${YELLOW}║  Broker   : $NLB_DNS${NC}"
echo -e "${BOLD}${YELLOW}║  Port TLS : 8883  |  Port plain : 1883                  ║${NC}"
echo -e "${BOLD}${YELLOW}║  User     : dashboard  |  Pass : $MQTT_PASS_DASHBOARD   ║${NC}"
echo -e "${BOLD}${YELLOW}║  Topic    : sensors/temperature                         ║${NC}"
echo -e "${BOLD}${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Tests validation prof${NC} :"
echo -e "    # Test Auth (avec creds valides)"
echo -e "    mosquitto_pub -h $NLB_DNS -p 1883 -u sensor -P '$MQTT_PASS_SENSOR' -t sensors/temperature -m '{\"value\":22.5}'"
echo -e "    # Test Auth (creds invalides → doit etre refuse)"
echo -e "    mosquitto_pub -h $NLB_DNS -p 1883 -u bad -P 'wrong' -t sensors/temperature -m 'test'"
echo -e "    # Test TLS (port 8883)"
echo -e "    mosquitto_pub -h $NLB_DNS -p 8883 --insecure -u sensor -P '$MQTT_PASS_SENSOR' -t sensors/temperature -m '{\"value\":22.5}'"
echo -e "    # Test ACL (topic non autorise → refuse)"
echo -e "    mosquitto_pub -h $NLB_DNS -p 1883 -u dashboard -P '$MQTT_PASS_DASHBOARD' -t sensors/temperature -m 'hack'"
echo -e "    # Ingestion NDJSON"
echo -e "    ssh -i ~/TPIOT/labsuser.pem ubuntu@$IP_BASTION_PUB 'tail -f /opt/ingestion/telemetry.ndjson'"
echo ""
echo -e "  ${BOLD}Bastion${NC} (acces serveur prive) :"
echo -e "    ssh -i ~/TPIOT/labsuser.pem ubuntu@$IP_BASTION_PUB"
echo -e "    ssh -J ubuntu@$IP_BASTION_PUB ubuntu@$IP_INGESTION"
echo ""
echo -e "  ${BOLD}Acces SSM${NC} :"
echo -e "    aws ssm start-session --target $INST_GW1 --region $REGION"
echo -e "    aws ssm start-session --target $INST_GW2 --region $REGION"
echo ""
echo -e "  ${BOLD}State file${NC}       : $STATE_FILE"
echo ""

log "Deploiement termine avec succes !"
