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

```bash
cd web-dashboard
cp .env.example .env      # édite MQTT_HOST avec le DNS du NLB
docker compose up --build
# Ouvre http://localhost:3000
```

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

## Vérifier le simulateur

```bash
# Vérifier le service sur l'instance ingestion
systemctl status iot-simulator
journalctl -u iot-simulator -f
```
