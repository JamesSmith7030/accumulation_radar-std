import threading
import time

import requests

from .config import FAPI

_lock = threading.Lock()
_last_request = 0.0
_min_interval = 0.05  # 50ms between requests (20 req/s)


def api_get(endpoint, params=None):
    """币安API请求（3次重试 + 令牌桶限速 + 线程安全）"""
    global _last_request
    url = f"{FAPI}{endpoint}"
    for attempt in range(3):
        with _lock:
            wait = _min_interval - (time.monotonic() - _last_request)
            if wait > 0:
                time.sleep(wait)
            _last_request = time.monotonic()
        try:
            resp = requests.get(url, params=params, timeout=10)
            if resp.status_code == 200:
                return resp.json()
            if resp.status_code == 429:
                time.sleep(2)
                continue
            return None
        except (requests.RequestException, ValueError):
            if attempt < 2:
                time.sleep(1)
    return None
