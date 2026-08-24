import os
import time
import hashlib
import hmac
import requests
import json
from datetime import datetime

# ---------- КОНФИГУРАЦИЯ ДЛЯ DELTA EXCHANGE ----------
# Замените на свои данные
API_KEY = "ВАШ_API_KEY"
API_SECRET = "ВАШ_API_SECRET"
BASE_URL = "https://api.delta.exchange"  # Для глобального продакшена
# Для тестнета используйте: https://testnet-api.delta.exchange

# Параметры стратегии (EMA 9/21 + RSI)
SYMBOL = "BTCUSDT"  # Торговая пара
FAST_EMA = 9
SLOW_EMA = 21
RSI_PERIOD = 14
RSI_LONG_THRESHOLD = 52  # Для длинной позиции
RSI_SHORT_THRESHOLD = 48 # Для короткой позиции

# ---------- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ----------
def generate_signature(secret, timestamp, method, path, body=""):
    """Генерация подписи HMAC-SHA256 для Delta Exchange [citation:8]"""
    data = f"{method}{timestamp}{path}{body}"
    signature = hmac.new(
        secret.encode('utf-8'),
        data.encode('utf-8'),
        hashlib.sha256
    ).hexdigest()
    return signature

def send_signed_request(method, path, body=None):
    """Отправка подписанного запроса к API Delta Exchange [citation:1][citation:6]"""
    timestamp = str(int(time.time() * 1000))
    body_str = json.dumps(body) if body else ""
    signature = generate_signature(API_SECRET, timestamp, method, path, body_str)
    
    headers = {
        "api-key": API_KEY,
        "timestamp": timestamp,
        "signature": signature,
        "Content-Type": "application/json"
    }
    
    url = f"{BASE_URL}{path}"
    response = requests.request(method, url, headers=headers, data=body_str if body else None)
    return response.json()

def get_ticker(symbol):
    """Получение данных тикера (без авторизации) [citation:1]"""
    response = requests.get(f"{BASE_URL}/v2/tickers/{symbol}")
    return response.json()

def get_historical_candles(symbol, resolution="15m", limit=200):
    """Получение исторических свечей [citation:1]"""
    params = {
        "symbol": symbol,
        "resolution": resolution,
        "limit": limit
    }
    response = requests.get(f"{BASE_URL}/v2/history/candles", params=params)
    return response.json()

def place_order(product_id, side, size, order_type="market", limit_price=None):
    """Размещение ордера на Delta Exchange [citation:6][citation:12]"""
    body = {
        "product_id": product_id,
        "side": side,
        "size": size,
        "order_type": order_type
    }
    if limit_price:
        body["limit_price"] = str(limit_price)
    
    return send_signed_request("POST", "/v2/orders", body)

def get_open_positions():
    """Получение открытых позиций"""
    response = send_signed_request("GET", "/v2/positions")
    return response.get("result", [])

# ---------- ОСНОВНАЯ ЛОГИКА СТРАТЕГИИ ----------
def calculate_ema(prices, period):
    """Расчет EMA (экспоненциальное скользящее среднее)"""
    if len(prices) < period:
        return None
    ema = [sum(prices[:period]) / period]
    multiplier = 2 / (period + 1)
    for price in prices[period:]:
        ema.append((price - ema[-1]) * multiplier + ema[-1])
    return ema[-1]

def calculate_rsi(prices, period=14):
    """Расчет RSI (индекс относительной силы)"""
    if len(prices) < period + 1:
        return None
    gains = []
    losses = []
    for i in range(1, len(prices)):
        change = prices[i] - prices[i-1]
        if change >= 0:
            gains.append(change)
            losses.append(0)
        else:
            gains.append(0)
            losses.append(abs(change))
    
    avg_gain = sum(gains[-period:]) / period
    avg_loss = sum(losses[-period:]) / period
    
    if avg_loss == 0:
        return 100
    rs = avg_gain / avg_loss
    return 100 - (100 / (1 + rs))

def get_signal():
    """Получение торгового сигнала на основе EMA + RSI [citation:3]"""
    # Получаем свечи для расчета индикаторов
    candles = get_historical_candles(SYMBOL, "15m", 200)
    if "result" not in candles or not candles["result"]:
        print("Ошибка получения свечей")
        return None
    
    # Извлекаем цены закрытия
    closes = [float(c[4]) for c in candles["result"]]  # c[4] - цена закрытия
    
    # Расчет EMA
    ema_fast = calculate_ema(closes, FAST_EMA)
    ema_slow = calculate_ema(closes, SLOW_EMA)
    
    # Расчет RSI
    rsi = calculate_rsi(closes, RSI_PERIOD)
    
    if ema_fast is None or ema_slow is None or rsi is None:
        return None
    
    print(f"EMA9: {ema_fast:.2f}, EMA21: {ema_slow:.2f}, RSI: {rsi:.2f}")
    
    # Проверка сигналов [citation:3]
    # Длинная позиция: EMA9 > EMA21 И RSI > 52
    if ema_fast > ema_slow and rsi > RSI_LONG_THRESHOLD:
        return "LONG"
    # Короткая позиция: EMA9 < EMA21 И RSI < 48
    elif ema_fast < ema_slow and rsi < RSI_SHORT_THRESHOLD:
        return "SHORT"
    
    return None

def get_product_id(symbol):
    """Получение product_id для символа"""
    response = requests.get(f"{BASE_URL}/v2/products")
    if "result" in response.json():
        for product in response.json()["result"]:
            if product.get("symbol") == symbol:
                return product.get("id")
    return None

def main():
    print(f"Запуск торгового бота для {SYMBOL}")
    print(f"Стратегия: EMA{FAST_EMA}/{SLOW_EMA} + RSI{RSI_PERIOD}")
    print("-" * 50)
    
    # Получаем product_id для символа
    product_id = get_product_id(SYMBOL)
    if not product_id:
        print(f"Ошибка: символ {SYMBOL} не найден")
        return
    
    print(f"Product ID: {product_id}")
    
    while True:
        try:
            # Получаем сигнал
            signal = get_signal()
            
            if signal:
                # Проверяем, есть ли уже открытая позиция
                positions = get_open_positions()
                has_position = False
                for pos in positions:
                    if pos.get("product_id") == product_id and float(pos.get("size", 0)) != 0:
                        has_position = True
                        break
                
                if has_position:
                    print(f"Позиция уже открыта, пропускаем сигнал {signal}")
                else:
                    # Определяем сторону и размер
                    side = "buy" if signal == "LONG" else "sell"
                    size = 10  # Размер позиции (настройте под свой риск)
                    
                    print(f"Сигнал: {signal}! Размещаем рыночный ордер...")
                    order_result = place_order(product_id, side, size, "market")
                    print(f"Результат: {order_result}")
            
            # Ждем перед следующим циклом
            time.sleep(60)  # Проверка каждую минуту
            
        except Exception as e:
            print(f"Ошибка: {e}")
            time.sleep(30)

if __name__ == "__main__":
    main()
