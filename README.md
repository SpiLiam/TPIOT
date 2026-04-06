# TP IoT — Infrastructure AWS MQTT

Déploiement d'une architecture IoT complète sur AWS via CLI uniquement (sans Terraform).

---

## Architecture générale

### Schéma réseau

```
Internet / App Android / Dashboard Web
        │
        │ TCP:1883 (MQTT plaintext)
        │ TCP:8883 (MQTT TLS)
        ▼
┌─────────────────────────────────────────────┐
│         Network Load Balancer (NLB)         │
│   Layer 4 TCP — répartition entre GW1/GW2  │
│   Health check TCP:1883 toutes les 30s      │
└──────────────┬──────────────────────────────┘
               │
       ┌───────┴────────┐
       ▼                ▼
┌──────────────┐  ┌──────────────┐     ┌──────────────┐
│  mqtt-gw1    │  │  mqtt-gw2    │     │  snort-ids   │
│  Mosquitto   │  │  Mosquitto   │     │  IDS passif  │
│  10.0.1.x    │  │  10.0.1.x    │     │  10.0.1.x    │
│  [DMZ]       │  │  [DMZ]       │ ◄── │  [DMZ]       │
└──────┬───────┘  └──────┬───────┘     └──────▲───────┘
       │                 │                    │
       │   MQTT bridge   │        VXLAN UDP:4789
       └────────┬────────┘      (Traffic Mirroring)
                │
                ▼
        ┌──────────────┐
        │  ingestion   │
        │  Python sub  │
        │  10.0.2.x    │
        │  [Private]   │
        └──────────────┘
```

### Flux de données

```
Capteur (simulateur Python)
    │ publish sensors/temperature
    ▼
NLB → mqtt-gw1 ou mqtt-gw2 (Mosquitto)
    │
    ├──► App Android         (subscribe MQTT:1883) → affichage temps réel
    ├──► Dashboard Web       (subscribe via Node.js + WebSocket) → graphique
    ├──► Ingestion backend   (subscribe via bridge MQTT) → log JSON
    └──► Snort IDS           (copie VXLAN via Traffic Mirroring) → alertes
```

---

## Composants

### Network Load Balancer (NLB)
- Opère au **Layer 4 (TCP)** — ne lit pas le contenu MQTT
- Répartit les connexions entre GW1 et GW2 en round-robin
- Port **1883** (plaintext) pour l'app Android et le dashboard
- Port **8883** (TLS) pour la production
- Si GW1 tombe, bascule automatiquement sur GW2

### MQTT Gateways — Mosquitto (GW1 + GW2)
- Broker MQTT open source, standard industrie
- Deux instances pour la **haute disponibilité**
- Reçoit les messages des capteurs et les redistribue aux subscribers
- Peut forwarder vers l'ingestion via un **MQTT bridge**
- `allow_anonymous true` pour le TP (pas d'authentification requise)

### Snort IDS — Détection d'intrusion
- Mode **passif** : analyse uniquement, ne bloque pas le trafic
- Reçoit une **copie** du trafic via **VPC Traffic Mirroring** (comme un span port de switch)
- Le trafic mirroré transite en **VXLAN sur UDP:4789**
- Règles : détecte les connexions MQTT, flood, brute force

### Instance Ingestion (Python)
- Subscribes à tous les topics (`#`) et log chaque message
- Dans le **subnet privé** → inaccessible depuis internet
- Héberge également le simulateur de température

### Simulateur de capteur (Python)
- Publie sur `sensors/temperature` toutes les 5 secondes
- Payload JSON : `{"sensor_id", "value", "unit", "timestamp"}`
- Température sinusoïdale : base 22°C ± 4°C + bruit aléatoire ±0.5°C

---

## Sécurité en couches

| Couche | Mécanisme | Rôle |
|--------|-----------|------|
| Réseau | **NACL** (Network ACL) | Firewall stateless au niveau subnet |
| Instance | **Security Group** | Firewall stateful au niveau instance |
| Accès admin | **AWS SSM** | Accès sans SSH exposé (port 22 fermé) |
| Supervision | **Snort IDS** | Détection d'anomalies sur le trafic MQTT |
| Logs | **CloudWatch** | Centralisation logs + alarmes CPU/status |

### Pourquoi ces choix ?
- **NLB vs ALB** : MQTT est du TCP pur, l'ALB ne gère que HTTP/HTTPS → NLB obligatoire
- **Traffic Mirroring** : analyse passive sans impacter les performances
- **SSM** : remplace SSH, pas de clé à distribuer, accès audité dans CloudWatch
- **Subnet privé pour l'ingestion** : le backend n'est jamais exposé directement

---

## Déploiement

```bash
git clone https://github.com/SpiLiam/TPIOT.git
cd TPIOT
bash deploy.sh
```

### Ce que fait `deploy.sh` étape par étape

#### 1/14 — Prérequis & Identité
Vérifie que l'AWS CLI est configurée et récupère le compte AWS actif.
```bash
aws sts get-caller-identity
```

#### 2/14 — AMI Ubuntu 22.04
Cherche automatiquement la dernière image Ubuntu 22.04 LTS dans la région.
```bash
aws ec2 describe-images --owners 099720109477 \
  --filters "Name=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
```

#### 3/14 — VPC
Crée le réseau virtuel privé `10.0.0.0/16` avec le DNS activé.
```bash
aws ec2 create-vpc --cidr-block 10.0.0.0/16
```

#### 4/14 — Subnets
Crée deux sous-réseaux :
- **DMZ** `10.0.1.0/24` — exposé, accueille les brokers MQTT et le NLB
- **Privé** `10.0.2.0/24` — isolé, accueille l'ingestion
- Le subnet DMZ a l'auto-assign public IP activé
```bash
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24   # DMZ
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24   # Privé
aws ec2 modify-subnet-attribute --subnet-id $SUBNET_DMZ --map-public-ip-on-launch
```

#### 5/14 — Internet Gateway + NAT Gateway
- **IGW** : permet au subnet DMZ d'accéder à Internet (entrée/sortie)
- **NAT GW** : permet au subnet privé de sortir sur Internet sans être exposé
```bash
aws ec2 create-internet-gateway
aws ec2 allocate-address --domain vpc          # EIP pour le NAT
aws ec2 create-nat-gateway --subnet-id $SUBNET_DMZ --allocation-id $EIP
```

#### 6/14 — Tables de routage
- DMZ → IGW (trafic vers Internet)
- Privé → NAT GW (sortie uniquement)
```bash
aws ec2 create-route-table --vpc-id $VPC_ID
aws ec2 create-route --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
```

#### 7/14 — Security Groups
Trois groupes de sécurité (pare-feux au niveau instance) :
- **SG GW** : autorise TCP 1883 et 8883 depuis internet
- **SG Snort** : autorise UDP 4789 (VXLAN Traffic Mirroring)
- **SG Ingestion** : autorise TCP 1883 depuis les GW uniquement
```bash
aws ec2 create-security-group --group-name iot-mqtt-gw --vpc-id $VPC_ID
aws ec2 authorize-security-group-ingress --protocol tcp --port 1883 --cidr 0.0.0.0/0
aws ec2 authorize-security-group-ingress --protocol tcp --port 8883 --cidr 0.0.0.0/0
```

#### 8/14 — NACLs
Listes de contrôle d'accès réseau (pare-feux stateless au niveau subnet) :
- **DMZ** : autorise SSH:22, MQTT:1883, MQTT-TLS:8883, ephémères, bloque tout le reste
- **Privé** : autorise MQTT:1883 depuis DMZ uniquement, ephémères via NAT
```bash
aws ec2 create-network-acl --vpc-id $VPC_ID
aws ec2 create-network-acl-entry --rule-number 100 --protocol tcp \
  --port-range From=1883,To=1883 --rule-action allow
```

#### 9/14 — IAM Role
Crée un rôle EC2 avec deux politiques :
- `AmazonSSMManagedInstanceCore` → accès SSM (pas de SSH)
- `CloudWatchAgentServerPolicy` → envoi des logs CloudWatch
```bash
aws iam create-role --role-name iot-mqtt-ec2-role
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy
```

#### 10/14 — Instances EC2
Lance 4 instances Ubuntu 22.04 avec script de bootstrap (userdata) :

| Instance | Type | Subnet | Rôle |
|----------|------|--------|------|
| `mqtt-gw1` | t3.small | DMZ | Mosquitto broker |
| `mqtt-gw2` | t3.small | DMZ | Mosquitto broker (HA) |
| `snort-ids` | t3.medium | DMZ | IDS Snort passif |
| `ingestion` | t3.small | Privé | Python subscriber + simulateur |

Le userdata installe automatiquement Mosquitto, SSM agent, CloudWatch agent.
```bash
aws ec2 run-instances --image-id $AMI --instance-type t3.small \
  --user-data file:///tmp/userdata_mqtt_gw.sh
```

#### 11/14 — Network Load Balancer
NLB TCP (Layer 4) sur le subnet DMZ, répartit le trafic entre GW1 et GW2.
```bash
aws elbv2 create-load-balancer --name iot-mqtt-nlb --type network --subnets $SUBNET_DMZ
aws elbv2 create-target-group --protocol TCP --port 8883 --vpc-id $VPC_ID
aws elbv2 create-listener --protocol TCP --port 8883
```

#### 12/14 — VPC Traffic Mirroring
Copie le trafic TCP des deux brokers vers Snort (VXLAN UDP:4789), sans impacter les performances.
```bash
aws ec2 create-traffic-mirror-target --network-interface-id $ENI_SNORT
aws ec2 create-traffic-mirror-filter
aws ec2 create-traffic-mirror-session --network-interface-id $ENI_GW1 \
  --traffic-mirror-target-id $MIRROR_TARGET
```

#### 13/14 — CloudWatch Logs + Alarmes
Log groups (rétention 30 jours) et alarmes CPU/status avec notifications SNS.
```bash
aws logs create-log-group --log-group-name /iot-mqtt/mqtt-gateway
aws cloudwatch put-metric-alarm --alarm-name cpu-high --threshold 80
aws sns create-topic --name iot-mqtt-alerts
```

#### 14/14 — Port 1883 + Simulateur
- Ouvre le port 1883 sur le NLB pour l'app Android et le dashboard
- Déploie le simulateur de température via SSM comme service systemd
```bash
aws elbv2 create-listener --protocol TCP --port 1883
aws ssm send-command --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl start iot-simulator"]'
```

À la fin, le DNS du NLB est affiché avec toutes les informations de connexion.

---

## Suppression

```bash
bash destroy.sh
```

Tape `DESTROY` pour confirmer. Supprime toutes les ressources dans l'ordre :
Traffic Mirroring → NLB → EC2 → NAT GW → IGW → VPCs (y compris orphelins) → CloudWatch → IAM

---

## App Android

Projet Kotlin dans `android-app/` — ouvrir dans Android Studio.

- **Build** : `Build → Build APK(s)`
- APK généré dans `app/build/outputs/apk/debug/`
- Appuie sur ⚙ pour configurer l'adresse du broker

| Paramètre | Valeur |
|-----------|--------|
| Broker | DNS du NLB (affiché à la fin de `deploy.sh`) |
| Port | 1883 |
| Topic | `sensors/temperature` |

---

## Dashboard Web (Docker)

Récupère d'abord le DNS du NLB :
```bash
aws elbv2 describe-load-balancers --region us-east-1 \
  --names "iot-mqtt-nlb" \
  --query 'LoadBalancers[0].DNSName' \
  --output text
```

```bash
cd web-dashboard
cp .env.example .env      # édite MQTT_HOST avec le DNS du NLB récupéré ci-dessus
docker compose up --build
# Ouvre http://localhost:3000
```

Le broker peut aussi être changé **à chaud depuis l'interface** via le bouton **⚙ Broker** en haut à droite — sans redémarrer le container.

Fonctionnalités :
- Température courante avec code couleur
- Graphique d'évolution (60 derniers points)
- Statistiques min / max / moyenne
- Historique des 20 dernières mesures
- Statut de connexion MQTT en temps réel (WebSocket)

### Batterie de tests

```bash
docker compose --profile tests run --rm tests
```

6 tests automatisés :
1. Connectivité TCP au broker
2. Connexion MQTT
3. Réception de messages sur `sensors/temperature`
4. Roundtrip publish/subscribe
5. 5 connexions simultanées
6. Débit de messages (fenêtre 20s)

---

## Accès aux instances (SSM — pas de SSH)

```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

---

## Debug & Troubleshooting

### Récupérer les IPs et DNS actuels

```bash
# DNS du NLB
aws elbv2 describe-load-balancers --region us-east-1 --names "iot-mqtt-nlb" \
  --query 'LoadBalancers[0].DNSName' --output text

# IPs publiques des GW (changent à chaque reboot)
aws ec2 describe-instances --region us-east-1 \
  --filters "Name=tag:Name,Values=iot-mqtt-mqtt-gw1,iot-mqtt-mqtt-gw2" \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`].Value|[0],PublicIP:PublicIpAddress,State:State.Name}' \
  --output table
```

### Vérifier la santé du NLB

```bash
TG=$(aws elbv2 describe-target-groups --names "iot-mqtt-tg-mqtt-1883" \
  --query 'TargetGroups[0].TargetGroupArn' --output text --region us-east-1)
aws elbv2 describe-target-health --target-group-arn "$TG" --region us-east-1 \
  --query 'TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State}' --output table
```

→ Si `unhealthy` : Mosquitto ne répond pas sur le port 1883 (voir section Mosquitto ci-dessous)

### Vérifier / relancer Mosquitto sur une GW

```bash
# Remplace GW_IP par l'IP publique de la GW
chmod 400 ~/labsuser.pem
ssh -i ~/labsuser.pem ubuntu@<GW_IP> "sudo systemctl status mosquitto --no-pager | head -8; sudo ss -tlnp | grep 1883"

# Si arrêté, relancer :
ssh -i ~/labsuser.pem ubuntu@<GW_IP> "sudo systemctl start mosquitto"
```

Si Mosquitto refuse de démarrer (erreur config) :
```bash
ssh -i ~/labsuser.pem ubuntu@<GW_IP> "sudo bash -s" << 'EOF'
cat > /etc/mosquitto/mosquitto.conf << 'MQTTCONF'
pid_file /run/mosquitto/mosquitto.pid
persistence true
persistence_location /var/lib/mosquitto/
log_dest file /var/log/mosquitto/mosquitto.log

listener 1883 0.0.0.0
allow_anonymous true
max_connections 500
MQTTCONF
rm -f /etc/mosquitto/conf.d/mqtt-gw.conf
pkill mosquitto 2>/dev/null; sleep 1
systemctl reset-failed mosquitto
systemctl start mosquitto
EOF
```

### Vérifier / relancer le simulateur de température

```bash
# Vérifier si le simulateur tourne
ssh -i ~/labsuser.pem ubuntu@<GW_IP> "ps aux | grep simulator | grep -v grep; tail -5 /tmp/simulator.log"

# Relancer le simulateur si mort
ssh -i ~/labsuser.pem ubuntu@<GW_IP> "sudo bash -s" << 'EOF'
cat > /tmp/simulator.py << 'PYEOF'
import json, math, random, time, paho.mqtt.client as mqtt
client = mqtt.Client()
client.connect("localhost", 1883)
client.loop_start()
t = 0
while True:
    temp = round(22.0 + 4.0 * math.sin(2 * math.pi * t / 60) + random.uniform(-0.5, 0.5), 2)
    payload = json.dumps({"sensor_id": "temp-sensor-01", "value": temp, "unit": "celsius",
                          "timestamp": int(time.time()), "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
    client.publish("sensors/temperature", payload, qos=1)
    print(f"Publie: {temp}C")
    t += 5
    time.sleep(5)
PYEOF
nohup python3 /tmp/simulator.py > /tmp/simulator.log 2>&1 &
echo "PID: $!"
EOF
```

> **Note** : les IPs publiques des GW changent à chaque reboot. Récupère la nouvelle IP avec la commande `describe-instances` ci-dessus.

### Tester la connectivité MQTT manuellement

```bash
# Depuis la machine EC2 (nécessite mosquitto-clients)
mosquitto_sub -h iot-mqtt-nlb-xxx.elb.us-east-1.amazonaws.com -p 1883 -t "sensors/temperature" -v

# Publier un message de test
mosquitto_pub -h iot-mqtt-nlb-xxx.elb.us-east-1.amazonaws.com -p 1883 \
  -t "sensors/temperature" \
  -m '{"sensor_id":"test","value":25.0,"unit":"celsius","timestamp":0,"timestamp_iso":"2026-01-01T00:00:00Z"}'
```

### Problème : app Android / dashboard ne reçoit rien

1. Vérifier que le NLB targets sont `healthy` (voir ci-dessus)
2. Vérifier que le simulateur publie (`tail -f /tmp/simulator.log`)
3. Vérifier que le broker dans l'app / dashboard correspond au DNS NLB actuel
4. Tester avec `mosquitto_sub` pour isoler le problème

### Vérifier SSM

```bash
aws ssm describe-instance-information --region us-east-1 \
  --query 'InstanceInformationList[*].{ID:InstanceId,Ping:PingStatus}' --output table
```
