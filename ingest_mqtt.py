import socket, struct, json, threading, time, os

GWS = [("10.1.1.29", 1883), ("10.1.3.180", 1883)]
TOPIC = "sensors/temperature"
USER = "ingestion"
PASS = "Ingestion2024!"
CLIENT_ID_PREFIX = "ingest"
OUTPUT = "/opt/ingestion/telemetry.ndjson"
LOCK = threading.Lock()

def encode_str(s):
    b = s.encode()
    return struct.pack("!H", len(b)) + b

def build_connect(client_id, user, pwd):
    proto = encode_str("MQTT") + b'\x04\xc2\x00\x3c'
    payload = encode_str(client_id) + encode_str(user) + encode_str(pwd)
    var = proto + payload
    rem = len(var)
    enc = []
    while True:
        d = rem & 0x7F
        rem >>= 7
        if rem: d |= 0x80
        enc.append(d)
        if not rem: break
    return bytes([0x10] + enc) + var

def build_subscribe(topic, pkt_id=1):
    payload = struct.pack("!H", pkt_id) + encode_str(topic) + b'\x01'
    rem = len(payload)
    enc = []
    while True:
        d = rem & 0x7F
        rem >>= 7
        if rem: d |= 0x80
        enc.append(d)
        if not rem: break
    return bytes([0x82] + enc) + payload

def build_pingreq():
    return b'\xc0\x00'

def decode_remaining(sock):
    mul, val, shift = 1, 0, 0
    while True:
        b = sock.recv(1)
        if not b: return None
        x = b[0]
        val += (x & 0x7F) * mul
        mul *= 128
        if not (x & 0x80): break
    return val

def recv_packet(sock):
    hdr = sock.recv(1)
    if not hdr: return None, 0, None
    ptype = hdr[0] >> 4
    flags = hdr[0] & 0x0F
    rem = decode_remaining(sock)
    if rem is None: return None, 0, None
    data = b''
    while len(data) < rem:
        chunk = sock.recv(rem - len(data))
        if not chunk: return None, 0, None
        data += chunk
    return ptype, flags, data

def run(host, port, idx):
    client_id = CLIENT_ID_PREFIX + str(idx)
    while True:
        try:
            s = socket.socket()
            s.settimeout(30)
            s.connect((host, port))
            s.send(build_connect(client_id, USER, PASS))
            ptype, _, d = recv_packet(s)
            if ptype != 2 or (d and d[1] != 0):
                print("CONNACK fail " + str(d[1] if d else "?"))
                s.close(); time.sleep(5); continue
            print("Connected to " + host)
            s.send(build_subscribe(TOPIC))
            s.settimeout(60)
            last_ping = time.time()
            while True:
                if time.time() - last_ping > 25:
                    s.send(build_pingreq())
                    last_ping = time.time()
                try:
                    ptype, flags, data = recv_packet(s)
                except socket.timeout:
                    s.send(build_pingreq())
                    last_ping = time.time()
                    continue
                if ptype is None: break
                if ptype == 3:
                    i = 0
                    tlen = struct.unpack("!H", data[i:i+2])[0]; i += 2 + tlen
                    qos = (flags >> 1) & 0x03
                    if qos > 0: i += 2  # skip packet identifier
                    try:
                        msg = json.loads(data[i:])
                        row = json.dumps({"ts": time.time(), "broker": host,
                                          "sensor_id": msg.get("sensor_id","?"),
                                          "value": msg.get("value"), "unit": msg.get("unit","celsius")})
                        with LOCK:
                            open(OUTPUT, "a").write(row + chr(10))
                        print("OK " + row[:60])
                    except Exception as e:
                        print("parse err " + str(e))
                elif ptype == 13:
                    pass
        except Exception as e:
            print("err " + host + " " + str(e))
            time.sleep(5)

os.makedirs("/opt/ingestion", exist_ok=True)
for i, (h, p) in enumerate(GWS):
    t = threading.Thread(target=run, args=(h, p, i), daemon=True)
    t.start()

print("Ingestion started, writing to " + OUTPUT)
while True:
    time.sleep(60)
