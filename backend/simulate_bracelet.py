"""read every five minutes"""
import random
import time
from datetime import datetime, timezone

import requests

URL = "http://127.0.0.1:8000/readings"
DEVICE_ID = "bracelet_001"

while True:
    reading = {
        "device_id": DEVICE_ID,
        "measured_at": datetime.now(timezone.utc).isoformat(),
        "heart_rate": random.randint(70, 80),
        "spo2": random.randint(96, 98),
        "temperature": round(random.uniform(36.4, 36.8), 1),
    }
    r = requests.post(URL, json=reading, timeout=5)
    print(r.status_code, reading)
    time.sleep(5)