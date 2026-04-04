# TP IoT — Infrastructure AWS MQTT

Déploiement d'une architecture IoT complète sur AWS via CLI uniquement (sans Terraform).

## Architecture

```
Internet
    │
    ▼
[Network Load Balancer]  ← port 1883 (demo) / 8883 (TLS)
    │
  [DMZ 10.0.1.0/24]
    ├── mqtt-gw1  (Mosquitto)
    └── mqtt-gw2  (Mosquitto)
         │ bridge
  [Private 10.0.2.0/24]
    ├── snort-ids  (IDS via Traffic Mirroring)
    └── ingestion  (Python subscriber + simulateur temp)
```

## Fichiers

| Fichier | Description |
|---------|-------------|
| `deploy.sh` | Déploiement complet en 14 étapes |
| `destroy.sh` | Suppression de toutes les ressources |
| `sensor_simulator.py` | Simulateur de capteur température (MQTT) |

## Prérequis

- AWS CLI configuré (`aws configure` ou credentials Academy)
- Droits EC2, VPC, ELB, SSM, IAM, CloudWatch
- Key pair `vockey` dans la région `us-east-1`

## Déploiement

```bash
bash deploy.sh
```

Le script crée dans l'ordre :
1. VPC + subnets (DMZ / Privé)
2. Internet Gateway + NAT Gateway
3. Route Tables + Security Groups + NACLs
4. IAM Role (SSM + CloudWatch)
5. 4 instances EC2 (2x MQTT GW, Snort IDS, Ingestion)
6. Network Load Balancer (port 8883 + 1883)
7. VPC Traffic Mirroring (GW → Snort)
8. CloudWatch Logs + Alarmes SNS
9. Port 1883 ouvert pour l'app Android
10. Simulateur température déployé automatiquement

À la fin, le DNS du NLB est affiché pour le configurer dans l'app Android.

## Suppression

```bash
bash destroy.sh
```

Tape `DESTROY` pour confirmer. Supprime toutes les ressources dans l'ordre inverse.

## App Android

Le projet Android se trouve dans `android-app/` (Kotlin + Paho MQTT).  
Configure l'adresse du broker via le bouton ⚙ dans l'app.

- **Broker** : DNS du NLB (affiché à la fin de `deploy.sh`)
- **Port** : 1883
- **Topic** : `sensors/temperature`

## Accès aux instances (SSM)

```bash
aws ssm start-session --target <instance-id> --region us-east-1
```

Aucun port SSH requis.
