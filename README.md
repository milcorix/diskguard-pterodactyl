<div align="center">
  <img src="icon.png" width="120" alt="DiskGuard Logo"/>
  <h1>DiskGuard</h1>
  <p><b>Pterodactyl Disk Protection Plugin</b></p>
  <p>
    <a href="https://xipher.ru"><img src="https://img.shields.io/badge/by-Xipher%20Cloud-6c63ff?style=flat-square&logo=cloud&logoColor=white"/></a>
    <img src="https://img.shields.io/badge/version-1.0.0-3ecfcf?style=flat-square"/>
    <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square"/>
    <img src="https://img.shields.io/badge/Panel-1.6–1.14-blue?style=flat-square"/>
  </p>
  <p>Разработано с любовью — <a href="https://xipher.ru">Xipher Cloud</a></p>
</div>

---

## Что это

DiskGuard защищает твой Pterodactyl от атак типа **Pterodactyl Crasher** — скриптов, которые мгновенно забивают весь диск хоста через `fallocate`, обходя стандартные лимиты Wings.

### Как работает атака

```python
# Pterodactyl-Crasher: 48 потоков, каждый:
subprocess.run(["fallocate", "-l", "1G", f".tmp_{uuid4()}"])
```

`fallocate` выделяет 1GB за миллисекунды на уровне ядра. Wings по умолчанию проверяет диск раз в **150 секунд** — за это время 155GB забиваются полностью.

---

## Защита

| Слой | Метод | Эффект |
|------|-------|--------|
| **Seccomp** | Блокирует syscall `fallocate` на уровне ядра | Скрипт падает мгновенно, 0 байт записано |
| **Wings config** | `disk_check_interval: 5` (было 150 сек) | Wings реагирует за 5 сек вместо 2.5 мин |
| **PID limit** | `container_pid_limit: 512` | Ограничивает параллельность атаки |
| **Monitor daemon** | Хост — каждые 3 сек, контейнеры — каждые 45 сек | Ловит альтернативные методы (dd и др.) |

### Результат тестирования

| | До DiskGuard | После DiskGuard |
|--|--|--|
| file.py (48 потоков) | **155GB за ~10 сек** | **0 байт, мгновенная блокировка** |
| Диск хоста | 100% | Не изменился |
| Реакция Wings | через 150 сек | через 5 сек + instant seccomp |

---

## Совместимость

### Pterodactyl Panel

| Версия | Поддержка |
|--------|-----------|
| 1.6.x | ✅ |
| 1.7.x | ✅ |
| 1.8.x | ✅ |
| 1.9.x | ✅ |
| 1.10.x | ✅ |
| 1.11.x | ✅ |
| 1.12.x | ✅ |
| 1.13.x | ✅ |
| 1.14.x | ✅ |
| 1.0-develop | ✅ |

### Wings

| Версия | Поддержка |
|--------|-----------|
| 1.7.x – 1.13.x | ✅ |

### Операционные системы

| ОС | Поддержка |
|----|-----------|
| Ubuntu 20.04 LTS | ✅ |
| Ubuntu 22.04 LTS | ✅ |
| Ubuntu 24.04 LTS | ✅ |
| Debian 11 | ✅ |
| Debian 12 | ✅ |
| CentOS Stream 8/9 | ✅ |

### Требования

- Docker **≥ 20.10**
- Blueprint **≥ alpha-09**
- Root-доступ на ноде Wings

---

## Установка

### Через Blueprint (рекомендуется)

```bash
blueprint -install diskguard.blueprint
```

### Вручную

```bash
bash install.sh
```

Скрипт автоматически:
- Деплоит seccomp-профиль `/etc/docker/seccomp-diskguard.json`
- Патчит Wings config (`disk_check_interval: 5`, `container_pid_limit: 512`)
- Устанавливает и запускает systemd-сервис мониторинга
- Перезапускает Docker и Wings

> **Мульти-нода:** запусти `install.sh` на каждой ноде Wings отдельно.

---

## Проверка

```bash
# Статус защиты
systemctl status diskguard wings docker

# Лог монитора в реальном времени
journalctl -u diskguard -f

# Тест блокировки fallocate внутри контейнера
docker exec <container_id> bash -c \
  "fallocate -l 1G /tmp/test && echo FAIL || echo BLOCKED"
```

Ожидаемый результат:
```
fallocate: fallocate failed: No space left on device
BLOCKED
```

---

## Файлы плагина

```
diskguard/
├── conf.yml                  — Blueprint конфиг
├── icon.png                  — Иконка плагина
├── install.sh                — Установщик (запускается автоматически)
├── diskguard-monitor.sh      — Демон мониторинга (хост 3 с, du контейнеров 45 с)
├── diskguard.service         — Systemd unit
└── wings-seccomp.patch       — Патч Wings для компиляции из исходников
```

---

## Лицензия

MIT License — свободное использование, распространение и модификация.

---

<div align="center">
  <br>
  <a href="https://xipher.ru">
    <img src="https://img.shields.io/badge/Xipher%20Cloud-xipher.ru-6c63ff?style=for-the-badge&logo=cloud&logoColor=white"/>
  </a>
  <br><br>
  Разработано с ❤️ командой <a href="https://xipher.ru"><b>Xipher Cloud</b></a>
</div>
