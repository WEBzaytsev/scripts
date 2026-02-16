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

