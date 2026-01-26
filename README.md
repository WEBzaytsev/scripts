## BBR

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/enable-bbr.sh?v=$(date +%s)" | sudo sh
```

```bash
wget -qO- "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/enable-bbr.sh?v=$(date +%s)" | sudo sh
```

---

## SSH Config

### Интерактивная настройка порта

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash
```

### Только порт (неинтерактивно)

```bash
# Фиксированный порт
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- --port 22222 --yes

# Случайный порт
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- --random-port --yes
```

### Добавление SSH ключа (только авторизация по ключу)

```bash
KEY="ssh-ed25519 AAAAC3..." 
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY"
```

### Ключ + случайный порт (неинтерактивно)

```bash
KEY="ssh-ed25519 AAAAC3..." 
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY" --random-port --yes
```

### Ключ + фиксированный порт (неинтерактивно)

```bash
KEY="ssh-ed25519 AAAAC3..." 
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY" --port 22222 --yes
```

---

## UFW Firewall

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ufw-config.sh?v=$(date +%s)" -o ufw-config.sh && sudo bash ufw-config.sh
```

```bash
wget -qO ufw-config.sh "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ufw-config.sh?v=$(date +%s)" && sudo bash ufw-config.sh
```

---

## Генерация SSH ключа

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

Показать публичный ключ:

```bash
cat ~/.ssh/id_ed25519.pub
```

---

## Ручная настройка SSH (альтернатива скрипту)

### 1) Положить ключ на сервер

```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub USER@HOST
```

Или через скрипт:

```bash
KEY=$(cat ~/.ssh/id_ed25519.pub)
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY"
```

### 2) Запретить вход по паролю

Конфиг:

```bash
sudo nano /etc/ssh/sshd_config
```

```text
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
```

Проверка:

```bash
sudo sshd -t
```

Применить:

```bash
sudo systemctl restart ssh && sudo systemctl restart sshd
```

### 3) Сменить SSH-порт

Выберем порт, например `2222`.

### 4.1 В конфиге SSH

```bash

sudo  nano  /etc/ssh/sshd_config

```

Пиши:

```text

Port 2222

```

(Если там был `Port 22` — замени.)

Проверка:

```bash

sudo  sshd  -t

```

Рестарт:

```bash

sudo  systemctl  restart  ssh  || sudo  systemctl  restart  sshd

```

### 4.2 Открыть порт в фаерволе (если он включён)

**UFW (Ubuntu/Debian часто):**

```bash

sudo  ufw  allow  2222/tcp

sudo  ufw  status

```
