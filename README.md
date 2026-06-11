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

## Clear SSH Keys

Удаляет все authorized_keys у root и всех пользователей (с бэкапами `*.bak.<timestamp>`), проверяет sshd_config на нестандартные пути `AuthorizedKeysFile`.

### Оставить только новый ключ (рекомендуется)

Сначала добавляет указанный ключ, затем удаляет все остальные — доступ не теряется:

```bash
KEY="ssh-ed25519 AAAA..."
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/clear-ssh-keys.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY" --yes --kill-sessions
```

### Интерактивно

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/clear-ssh-keys.sh?v=$(date +%s)" | sudo bash
```

### Неинтерактивно + завершить чужие SSH-сессии

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/clear-ssh-keys.sh?v=$(date +%s)" | sudo bash -s -- --yes --kill-sessions
```

### Ключи + сессии + перегенерация host-ключей

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/clear-ssh-keys.sh?v=$(date +%s)" | sudo bash -s -- --yes --kill-sessions --regen-host-keys
```

**ВАЖНО:** если запускали без `-k` — не закрывайте текущую сессию, сразу добавьте новый ключ:

```bash
KEY="ssh-ed25519 AAAA..."
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/ssh-config.sh?v=$(date +%s)" | sudo bash -s -- -k "$KEY"
```

---

## Docker Aliases

Установка docker-команд (dc, dcu, dcud, dcub, dcd, dcl, dcps и др.) в /etc/profile.d:

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/docker-aliases.sh?v=$(date +%s)" | sudo bash
```

С подключением алиасов для пользователя (добавляет source /etc/profile в ~/.bashrc):

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/docker-aliases.sh?v=$(date +%s)" | sudo bash -s -- --user "$USER"
```

---

## Docker Monitor (dozzle + beszel)

Интерактивная настройка docker compose для dozzle и beszel агентов:

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/docker-monitor.sh?v=$(date +%s)" | sudo bash
```

С указанием hub URL через флаг:

```bash
curl -sSL "https://cdn.jsdelivr.net/gh/WEBzaytsev/scripts@main/docker-monitor.sh?v=$(date +%s)" | sudo bash -s -- --hub-url "https://monitor.example.com"
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

