#!/usr/bin/env python3
"""
Simulateur de capteur de température IoT
Publie des mesures toutes les 5 secondes sur le broker MQTT local
Topic : sensors/temperature
"""

import json
import math
import random
import time
import signal
import sys
import paho.mqtt.client as mqtt

# ── Configuration ────────────────────────────────────────────────────────────
BROKER_HOST  = "localhost"   # On publie directement sur le broker local
BROKER_PORT  = 1883
TOPIC        = "sensors/temperature"
SENSOR_ID    = "temp-sensor-01"
INTERVAL_SEC = 5             # Intervalle entre chaque mesure
# ─────────────────────────────────────────────────────────────────────────────

running = True

def on_connect(client, userdata, flags, rc):
    codes = {
        0: "Connecté au broker MQTT",
        1: "Refusé : mauvaise version protocole",
        2: "Refusé : identifiant client invalide",
        3: "Refusé : serveur indisponible",
        4: "Refusé : mauvais user/password",
        5: "Refusé : non autorisé",
    }
    print(f"[MQTT] {codes.get(rc, f'Code inconnu : {rc}')}")

def on_disconnect(client, userdata, rc):
    if rc != 0:
        print(f"[MQTT] Déconnexion inattendue (code {rc}), tentative de reconnexion...")

def generate_temperature():
    """
    Simule une température réaliste :
    - Valeur de base 22°C
    - Variation sinusoïdale lente (cycle de 60s)
    - Bruit aléatoire ±0.5°C
    """
    t = time.time()
    base      = 22.0
    sine_wave = 4.0 * math.sin(2 * math.pi * t / 60)
    noise     = random.uniform(-0.5, 0.5)
    return round(base + sine_wave + noise, 2)

def signal_handler(sig, frame):
    global running
    print("\n[INFO] Arrêt du simulateur...")
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
        print(f"[ERREUR] Impossible de se connecter : {e}")
        sys.exit(1)

    client.loop_start()
    print(f"[INFO] Publication sur '{TOPIC}' toutes les {INTERVAL_SEC}s")
    print("[INFO] Ctrl+C pour arrêter\n")

    while running:
        temp = generate_temperature()
        payload = json.dumps({
            "sensor_id":  SENSOR_ID,
            "value":      temp,
            "unit":       "celsius",
            "timestamp":  int(time.time()),
            "timestamp_iso": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        })

        result = client.publish(TOPIC, payload, qos=1)
        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            print(f"[PUBLISH] {temp}°C → {TOPIC}")
        else:
            print(f"[ERREUR] Echec publication (code {result.rc})")

        time.sleep(INTERVAL_SEC)

    client.loop_stop()
    client.disconnect()
    print("[INFO] Simulateur arrêté proprement.")

if __name__ == "__main__":
    main()
