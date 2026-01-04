## BBR

```bash
curl -sSL https://raw.githubusercontent.com/WEBzaytsev/scripts/refs/heads/main/enable-bbr.sh | sudo sh
```

```bash
wget -qO- https://raw.githubusercontent.com/WEBzaytsev/scripts/refs/heads/main/enable-bbr.sh | sudo sh
```

---

## SSH Config

```bash
curl -sSL https://raw.githubusercontent.com/WEBzaytsev/scripts/refs/heads/main/ssh-config.sh -o ssh-config.sh && sudo bash ssh-config.sh
```

```bash
wget -qO ssh-config.sh https://raw.githubusercontent.com/WEBzaytsev/scripts/refs/heads/main/ssh-config.sh && sudo bash ssh-config.sh
```

---

```bash

ssh-keygen  -t  ed25519  

```

---

## 2) Положить ключ на сервер

```bash

ssh-copy-id  -i  ~/.ssh/id_ed25519.pub  USER@HOST

```

## 3) запретить вход по паролю

Конфиг:

```bash

sudo  nano  /etc/ssh/sshd_config

```

```text

PasswordAuthentication no

KbdInteractiveAuthentication no

ChallengeResponseAuthentication no

PubkeyAuthentication yes

```

ПроверОЧКА

```bash

sudo  sshd  -t

```

Применить:

```bash

sudo  systemctl  restart  ssh  && sudo  systemctl  restart  sshd

```

## 4) Сменить SSH-порт

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
