# TP IoT — Infrastructure AWS MQTT

Déploiement d'une architecture IoT complète sur AWS via CLI uniquement (sans Terraform).

## Architecture

```
Internet
    │
    ▼
[Network Load Balancer]  ← port 1883 (Android/demo) / 8883 (TLS)
    │
  [DMZ 10.0.1.0/24]
    ├── mqtt-gw1  (Mosquitto broker)
    └── mqtt-gw2  (Mosquitto broker)
         │ bridge
  [Private 10.0.2.0/24]
    ├── snort-ids  (IDS passif via Traffic Mirroring)
    └── ingestion  (Python subscriber + simulateur température)
```

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
aws ec2 describe-images --owners 099720109477 --filters "Name=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
```

#### 3/14 — VPC
Crée le réseau virtuel privé `10.0.0.0/16` avec le DNS activé.
```bash
aws ec2 create-vpc --cidr-block 10.0.0.0/16
```

#### 4/14 — Subnets
Crée deux sous-réseaux dans la VPC :
- **DMZ** `10.0.1.0/24` — exposé, accueille les brokers MQTT et le NLB
- **Privé** `10.0.2.0/24` — isolé, accueille Snort et l'ingestion
```bash
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.1.0/24   # DMZ
aws ec2 create-subnet --vpc-id $VPC_ID --cidr-block 10.0.2.0/24   # Privé
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
Crée et associe les routes :
- DMZ → IGW (trafic vers Internet)
- Privé → NAT GW (sortie uniquement)
```bash
aws ec2 create-route-table --vpc-id $VPC_ID
aws ec2 create-route --route-table-id $RT --destination-cidr-block 0.0.0.0/0 --gateway-id $IGW
```

#### 7/14 — Security Groups
Trois groupes de sécurité (pare-feux au niveau instance) :
- **SG GW** : autorise TCP 1883, 8883 depuis le NLB
- **SG Snort** : autorise UDP 4789 (VXLAN Traffic Mirroring)
- **SG Ingestion** : autorise TCP 1883 depuis les GW uniquement
```bash
aws ec2 create-security-group --group-name iot-mqtt-gw --vpc-id $VPC_ID
aws ec2 authorize-security-group-ingress --group-id $SG --protocol tcp --port 8883 --cidr 0.0.0.0/0
```

#### 8/14 — NACLs
Listes de contrôle d'accès réseau (pare-feux au niveau subnet) pour segmenter DMZ ↔ Privé.
```bash
aws ec2 create-network-acl --vpc-id $VPC_ID
aws ec2 create-network-acl-entry --network-acl-id $NACL --rule-number 100 --protocol tcp --port-range From=8883,To=8883 --rule-action allow
```

#### 9/14 — IAM Role
Crée un rôle EC2 avec deux politiques :
- `AmazonSSMManagedInstanceCore` → accès SSM (pas de SSH)
- `CloudWatchAgentServerPolicy` → envoi des logs CloudWatch
```bash
aws iam create-role --role-name iot-mqtt-ec2-role
aws iam attach-role-policy --role-name iot-mqtt-ec2-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
```

#### 10/14 — Instances EC2
Lance 4 instances Ubuntu 22.04 avec un script de bootstrap (userdata) :
| Instance | Type | Subnet | Rôle |
|----------|------|--------|------|
| `mqtt-gw1` | t3.small | DMZ | Mosquitto broker |
| `mqtt-gw2` | t3.small | DMZ | Mosquitto broker |
| `snort-ids` | t3.medium | Privé | IDS Snort |
| `ingestion` | t3.small | Privé | Python MQTT subscriber |
```bash
aws ec2 run-instances --image-id $AMI --instance-type t3.small --user-data file:///tmp/userdata_mqtt_gw.sh
```

#### 11/14 — Network Load Balancer
Crée un NLB TCP (Layer 4) sur le subnet DMZ pour répartir le trafic MQTT entre les deux brokers sur le port 8883.
```bash
aws elbv2 create-load-balancer --name iot-mqtt-nlb --type network --subnets $SUBNET_DMZ
aws elbv2 create-target-group --name iot-mqtt-tg --protocol TCP --port 8883 --vpc-id $VPC_ID
aws elbv2 create-listener --load-balancer-arn $NLB_ARN --protocol TCP --port 8883
```

#### 12/14 — VPC Traffic Mirroring
Copie le trafic TCP des deux brokers vers Snort en temps réel (VXLAN UDP 4789), sans impacter les performances — Snort analyse en mode passif.
```bash
aws ec2 create-traffic-mirror-target --network-interface-id $ENI_SNORT
aws ec2 create-traffic-mirror-filter
aws ec2 create-traffic-mirror-session --network-interface-id $ENI_GW1 --traffic-mirror-target-id $MIRROR_TARGET
```

#### 13/14 — CloudWatch Logs + Alarmes
Crée les groupes de logs (rétention 30 jours) et des alarmes CPU/status sur toutes les instances avec notifications SNS.
```bash
aws logs create-log-group --log-group-name /iot-mqtt/mqtt-gateway
aws cloudwatch put-metric-alarm --alarm-name cpu-high --threshold 80 --alarm-actions $SNS_ARN
aws sns create-topic --name iot-mqtt-alerts
```

#### 14/14 — Port 1883 + Simulateur
- Ouvre le port 1883 (MQTT plaintext) sur le NLB pour l'app Android
- Déploie le simulateur de température via SSM comme service systemd sur l'instance ingestion
```bash
aws ec2 authorize-security-group-ingress --port 1883
aws elbv2 create-listener --port 1883
aws ssm send-command --document-name AWS-RunShellScript --parameters 'commands=["systemctl start iot-simulator"]'
```

À la fin du script, le DNS du NLB est affiché avec les informations de connexion pour l'app Android.

---

## Suppression

```bash
bash destroy.sh
```

Tape `DESTROY` pour confirmer. Supprime toutes les ressources dans l'ordre inverse (Traffic Mirroring → NLB → EC2 → SGs → NAT → IGW → VPC → CloudWatch → IAM).

---

## App Android

Projet Kotlin dans `android-app/` — ouvrir dans Android Studio.

- **Build** : `Build → Build APK(s)`
- APK généré dans `app/build/outputs/apk/debug/`
- Au premier lancement, appuie sur ⚙ pour configurer l'adresse du broker

| Paramètre | Valeur |
|-----------|--------|
| Broker | DNS du NLB (affiché à la fin de `deploy.sh`) |
| Port | 1883 |
| Topic | `sensors/temperature` |

---

## Accès aux instances (SSM — pas de SSH)

```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

## Vérifier le simulateur

```bash
# Se connecter à l'instance ingestion
aws ssm start-session --target $INST_INGESTION --region us-east-1

# Vérifier le service
systemctl status iot-simulator
journalctl -u iot-simulator -f
```
