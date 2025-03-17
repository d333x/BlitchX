# BlitchX
BlitchX like in Mr.Robot

### Полный код и инструкция для **Blitch X** (Linux):

---

### 1. Структура проекта:
```
blitchx/
├── backend/
│   ├── server.py
│   ├── crypto.py
│   ├── tor_proxy.py
│   ├── requirements.txt
│   └── db/
│       └── (база данных SQLite)
└── frontend/
    ├── src/
    │   ├── components/
    │   │   ├── Terminal.jsx
    │   │   └── Chat.jsx
    │   ├── App.js
    │   └── index.js
    ├── package.json
    └── public/
        └── index.html
```

---

### 2. Backend (Python)

#### 2.1. Установка зависимостей:
```bash
sudo apt install -y python3 python3-pip nodejs npm tor
python3 -m venv venv
source venv/bin/activate
pip install fastapi uvicorn cryptography stem sqlalchemy websockets python-multipart
```

#### 2.2. `backend/server.py`:
```python
import os
import uuid
from fastapi import FastAPI, WebSocket
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from crypto import encrypt_aes, decrypt_aes
import sqlite3
import asyncio

app = FastAPI()
active_connections = {}
keys_db = sqlite3.connect('db/keys.db')

# Инициализация БД
def init_db():
    cursor = keys_db.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY,
            public_key TEXT
        )
    ''')
    keys_db.commit()

init_db()

# Генерация ключей
def generate_keys():
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    public_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return private_key, public_key.decode()

# WebSocket для чата
@app.websocket("/ws/{client_id}")
async def websocket_handler(websocket: WebSocket, client_id: str):
    await websocket.accept()
    active_connections[client_id] = websocket
    try:
        while True:
            data = await websocket.receive_text()
            target_id, encrypted_msg = data.split("|", 1)
            if target_id in active_connections:
                await active_connections[target_id].send_text(f"{client_id}|{encrypted_msg}")
    except Exception as e:
        del active_connections[client_id]

# API для регистрации
@app.post("/register")
async def register():
    client_id = str(uuid.uuid4())
    _, public_key = generate_keys()
    cursor = keys_db.cursor()
    cursor.execute('INSERT INTO users VALUES (?, ?)', (client_id, public_key))
    keys_db.commit()
    return {"client_id": client_id, "public_key": public_key}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

#### 2.3. `backend/crypto.py`:
```python
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.backends import default_backend
import os

def encrypt_aes(message: str, key: bytes):
    iv = os.urandom(16)
    padder = padding.PKCS7(128).padder()
    padded_data = padder.update(message.encode()) + padder.finalize()
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    encryptor = cipher.encryptor()
    ciphertext = encryptor.update(padded_data) + encryptor.finalize()
    return iv + ciphertext

def decrypt_aes(ciphertext: bytes, key: bytes):
    iv = ciphertext[:16]
    cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
    decryptor = cipher.decryptor()
    padded_plaintext = decryptor.update(ciphertext[16:]) + decryptor.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    plaintext = unpadder.update(padded_plaintext) + unpadder.finalize()
    return plaintext.decode()
```

#### 2.4. `backend/tor_proxy.py`:
```python
import stem.process
from stem.util import term

def start_tor():
    tor_process = stem.process.launch_tor_with_config(
        config = {
            'SocksPort': '9050',
            'ControlPort': '9051',
            'HiddenServiceDir': './hidden_service',
            'HiddenServicePort': '80 127.0.0.1:8000',
        },
        init_msg_handler = lambda line: print(term.format(line, term.Color.BLUE)),
    )
    return tor_process

if __name__ == "__main__":
    tor_proc = start_tor()
    input("Нажмите Enter для остановки Tor...")
    tor_proc.kill()
```

---

### 3. Frontend (React)

#### 3.1. Установка зависимостей:
```bash
cd frontend
npm install xterm @xterm/react xterm-addon-fit react-websocket @mui/material axios
```

#### 3.2. `frontend/src/components/Terminal.jsx`:
```javascript
import { useState, useEffect, useRef } from 'react';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import WebSocket from 'react-websocket';
import axios from 'axios';
import '@xterm/xterm/css/xterm.css';

export default function BlitchTerminal() {
  const terminalRef = useRef(null);
  const fitAddon = new FitAddon();
  const [clientId, setClientId] = useState('');
  const [aesKey, setAesKey] = useState('');

  useEffect(() => {
    const term = new Terminal({
      theme: { background: '#000', foreground: '#0f0' },
      cursorBlink: true,
    });

    term.loadAddon(fitAddon);
    term.open(terminalRef.current);
    fitAddon.fit();

    // Регистрация пользователя
    axios.post('http://localhost:8000/register')
      .then(response => {
        setClientId(response.data.client_id);
        term.writeln(`\r\nВаш ID: ${response.data.client_id}`);
        term.write('$ ');
      });

    // Обработка ввода
    term.onData(data => {
      if (data === '\r') {
        const command = term.buffer.active.getLine(term.buffer.active.cursorY)?.translateToString().trim();
        term.write('\r\n');
        handleCommand(command, term);
        term.write('$ ');
      } else {
        term.write(data);
      }
    });

    return () => term.dispose();
  }, []);

  const handleCommand = (command, term) => {
    if (command.startsWith('/msg ')) {
      const [_, targetId, ...msgParts] = command.split(' ');
      const message = msgParts.join(' ');
      term.writeln(`\r\n[Отправка] -> ${targetId}: ${message}`);
    }
  };

  return (
    <div>
      <div ref={terminalRef} style={{ width: '100%', height: '80vh' }} />
      <WebSocket url={`ws://localhost:8000/ws/${clientId}`} />
    </div>
  );
}
```

#### 3.3. Запуск фронтенда:
```bash
npm start
```

---

### 4. Интеграция с Tor

#### 4.1. Запустите Tor:
```bash
python3 tor_proxy.py
```

#### 4.2. Получите .onion-адрес:
```bash
cat ./hidden_service/hostname
```

---

### 5. Запуск всей системы

#### 5.1. В первом терминале (бэкенд):
```bash
source venv/bin/activate
uvicorn server:app --reload
```

#### 5.2. Во втором терминале (фронтенд):
```bash
cd frontend
npm start
```

#### 5.3. В третьем терминале (Tor):
```bash
python3 tor_proxy.py
```

---

### 6. Дополнительные функции

#### 6.1. Самоуничтожающиеся сообщения:
Добавьте в `server.py`:
```python
from datetime import datetime, timedelta

class SelfDestructMessage:
    def __init__(self, text, ttl=60):
        self.text = text
        self.expires = datetime.now() + timedelta(seconds=ttl)
    
    async def check(self):
        while datetime.now() < self.expires:
            await asyncio.sleep(1)
        self.text = "[УНИЧТОЖЕНО]"
```

#### 6.2. Шифрование метаданных:
Используйте `crypto.py` для двойного шифрования:
```python
def double_encrypt(data, key1, key2):
    return encrypt_aes(encrypt_aes(data, key1), key2)
```

---

### 7. Решение проблем

1. **Ошибки портов**:
   ```bash
   sudo lsof -i :8000 && kill -9 PID
   ```

2. **Проблемы с Tor**:
   ```bash
   sudo systemctl restart tor
   ```

3. **Сборка фронтенда**:
   ```bash
   rm -rf node_modules && npm install
   ```

---

Это **полная базовая реализация** Blitch X. Для расширения функционала добавьте:
- P2P-сеть через libp2p
- Интеграцию с Kali Linux (nmap, Metasploit)
- Голосовую модуляцию
- DRM-защиту от скриншотов
