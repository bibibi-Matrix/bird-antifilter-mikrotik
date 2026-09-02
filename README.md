# BIRD2 Antifilter Container for MikroTik RouterOS

> **Дисклеймер:** Проект создан в ознакомительных целях. Автор не несёт ответственности за любые последствия использования данного программного обеспечения. Используйте на свой страх и риск.

Docker-контейнер с BIRD2 для экспорта антифильтрованных маршрутов в MikroTik RouterOS через BGP.

---

## Возможности

### Загрузка и обработка списков
- Автоматическая загрузка IP-списков с [antifilter.download](https://antifilter.download) и [antifilter.network](https://antifilter.network)
- Индивидуальные переключатели для каждого списка в `bird2.conf`
- Поддержка пользовательских списков (custom lists) через mount
- **Поддержка IPv4 и IPv6** — обе версии протокола обрабатываются и экспортируются

### Валидация и очистка данных
- **Валидация CIDR** — некорректные записи обнаруживаются и пропускаются с предупреждением, не ломая остальной список
- **Чёрный список** — IP/CIDR из папки `black_list/` исключаются из финальных `.rsc` файлов
- **Разрешение перекрытий CIDR** — автоматическое обнаружение и удаление избыточных супернетов (маршруты, поглощающие более специфичные)

### Конфигурация (шаблон вместо генерации)
- `bird.conf` создаётся из **шаблона** `bird.conf.template` с плейсхолдерами
- Автоопределение Router ID и IP шлюза из маршрута по умолчанию
- Aвтоматическая подстановка include-ов для всех `.rsc` файлов
- Полный контроль над BGP-конфигурацией через редактирование шаблона

### Надёжность и безопасность
- Ежедневная автоматическая синхронизация (cron, по умолчанию 03:00) с ротацией логов, расписание настраивается через `SYNC_CRON`
- **BGP-мониторинг** — периодическая проверка состояния пиров и количества маршрутов с алертами (расписание через `MONITOR_CRON`)
- **Проверка конфига перед применением** (`birdc configure -p`) — при ошибке старый конфиг сохраняется
- **Graceful shutdown** — при остановке контейнера маршруты корректно отзываются
- **Healthcheck** — Docker отслеживает живость процесса BIRD2
- `flock` — защита от параллельных запусков синхронизации
- Работает без `privileged` режима — только `NET_ADMIN`
- DNS настраивается через переменные окружения

---

## Структура проекта

```
bird-mirkotik/
├── .github/workflows/build.yml   # GitHub Actions - сборка + публикация Release
├── Dockerfile                     # Alpine 3.22 + bird2
├── docker-compose.yml             # Конфигурация запуска
├── bin/
│   ├── bird2.sh                   # Основной скрипт синхронизации (v3.1.x)
│   └── entrypoint.sh              # Точка входа контейнера
└── etc/bird/
    ├── bird2.conf                 # Конфигурация источников списков
    ├── bird.conf.template         # Шаблон конфигурации BIRD2 (редактируется)
    ├── black_list/                # Исключаемые IP/CIDR (по файлам .lst)
    └── list_custom/               # Пользовательские списки
        ├── AWS-Amazon.lst
        ├── AnyDesk.lst
        ├── Cloudflare.lst
        ├── Discord.lst
        ├── Google.lst
        ├── MAX.lst
        ├── Meta.lst
        ├── Openh264.lst
        ├── Telegram.lst
        └── WebNovel.lst
```

---

## Установка

### Способ 1: Скачать готовый образ (рекомендуется)

1. Скачайте `bird2-antifilter.tar` из [Releases](https://github.com/bibibi-Matrix/bird-antifilter-mikrotik/releases)
2. Загрузите на MikroTik:
```routeros
/container/file add file-name=bird2-antifilter.tar url=<URL_к_файлу_на_сервере>
```

### Способ 2: Собрать самостоятельно

```bash
git clone https://github.com/bibibi-Matrix/bird-antifilter-mikrotik.git
cd bird-antifilter-mikrotik
docker build -t bird2-antifilter:latest .
docker save bird2-antifilter:latest -o bird2-antifilter.tar
```

---

## Настройка MikroTik RouterOS

### 1. Создание контейнера

```routeros
# Загрузить образ
/container/file add file-name=bird2-antifilter.tar url=<URL>

# Создать veth интерфейс
/interface veth add name=veth-bird2 address=192.168.34.2/24 master-port=ether1

# Создать контейнер
/container add name=bird2 \
    image=bird2-antifilter.tar \
    interface=veth-bird2 \
    root-dir=container1/bird2 \
    env-template="TZ=Europe/Moscow"

# Запустить
/container start numbers=bird2
```

### 2. Настройка BGP на MikroTik

```routeros
# Создать AS и peering
/routing/bgp/connection add name=bird2-conn \
    remote.address=192.168.34.2 \
    remote.as=64500 \
    local.address=192.168.34.1 \
    local.as=64501 \
    as=64501 \
    role=ebgp \
    hold-time=4m \
    passive=no
```

> **Примечание:** BIRD2 работает в режиме `passive on` — MikroTik инициирует BGP-подключение к контейнеру. Параметры BGP (local AS, AS пира, hold time) задаются в `bird2.conf`.

### 3. Firewall (если используется bridge)

Если контейнер работает через Docker bridge, добавьте подсеть в interface list LAN:

```routeros
/interface list member add list=LAN interface=<docker-bridge-interface>
```

Для NAT в интернет:

```routeros
/ip firewall nat add chain=srcnat \
    src-address=172.17.0.0/16 \
    out-interface-list=WAN \
    action=masquerade
```

---

## Конфигурация bird2.conf

Файл `etc/bird/bird2.conf` монтируется в контейнер как read-only. Управляйте источниками списков и поведением:

```ini
# === Antifilter Sources ===
antifilter_download=yes    # Мастер-переключатель antifilter.download
antifilter_network=no      # Мастер-переключатель antifilter.network

# antifilter.download - индивидуальные переключатели
ip=no
ipresolve=no
ipsum=no
subnet=no
allyouneed=yes
community=no

# antifilter.network - индивидуальные переключатели
nf_ip=yes
nf_ipsmart=yes
nf_ipsum=yes
nf_subnet=yes
nf_uablacklist=yes
nf_govno=yes
nf_ip6=yes

# === Blacklist ===
blacklist=yes              # Применять чёрный список

# === Overlap Resolution ===
overlap_check=yes          # Проверять и разрешать перекрытия
overlap_strategy=specific  # specific = удалить supernet; log_only = только логировать

# === BGP Settings ===
local_as=64500
gw_as=64501
hold_time=240

# === Monitoring ===
min_routes=1000    # Порог: алерт, если маршрутов меньше (0 = отключить)
```

### Источники antifilter.download

| Список | Описание |
|--------|----------|
| `ip` | Отдельные IP-адреса |
| `ipresolve` | Разрешённые IP-адреса |
| `ipsum` | Суммаризированные /24 префиксы |
| `subnet` | Подсети |
| `allyouneed` | Объединённый ipsum + subnet |
| `community` | Community списки |

### Источники antifilter.network

| Список | Описание |
|--------|----------|
| `nf_ip` | Отдельные IP-адреса |
| `nf_ipsmart` | Smart IP список |
| `nf_ipsum` | Суммаризированные /24 префиксы |
| `nf_subnet` | Подсети |
| `nf_uablacklist` | Ukraine blacklist |
| `nf_govno` | Government list |
| `nf_ip6` | IPv6 адреса |

---

## Чёрный список (Black List)

IP/CIDR для исключения из финальных маршрутов размещаются в папке `etc/bird/black_list/`. Каждый `.lst` файл в этой папке обрабатывается автоматически.

**Важно:** исходные `.lst` файлы не изменяются — исключение применяется на этапе формирования `.rsc` файлов.

Формат файла — одна запись на строку:

```
# Комментарии через #
10.0.0.0/8
192.168.0.0/16
172.16.0.0/12
1.2.3.4        # голый IP = /32
```

Применяется с 3-го шага. `0.0.0.0/0` отклоняется (удалил бы все маршруты).

---

## Конфигурация BIRD2 (шаблон)

Файл `etc/bird/bird.conf.template` монтируется read-only. Плейсхолдеры автоматически заменяются при каждой генерации:

| Плейсхолдер | Значение | Источник |
|-------------|----------|----------|
| `@@ROUTER_ID@@` | Router ID | автоопределение (или fallback `10.137.10.253`) |
| `@@GW_IP@@` | IP шлюза/BGP-соседа | автоопределение (или fallback `10.137.10.1`) |
| `@@LOCAL_AS@@` | Локальный AS | `bird2.conf` → `local_as` |
| `@@GW_AS@@` | AS пира | `bird2.conf` → `gw_as` |
| `@@HOLD_TIME@@` | Hold time | `bird2.conf` → `hold_time` |
| `@@INCLUDES@@` | Список include-ов `.rsc` | генерируется из `list_rsc/` |

Вы можете свободно редактировать статичные части шаблона (добавлять протоколы, менять фильтры, community и т.д.) — они не перезаписываются. Только плейсхолдеры обновляются скриптом.

---

## Пользовательские списки (Custom Lists)

Файлы `.lst` в папке `etc/bird/list_custom/` автоматически копируются в контейнер при каждом запуске. Все списки загружаются безусловно (переключатели не используются).

Формат файла — одна запись на строку:

```
# Комментарии через #
192.168.0.0/16
10.0.0.0/8
1.2.3.4
```

---

## Как это работает

При запуске контейнер выполняет последовательность шагов:

1. **sync_custom_lists** — копирует все `.lst` из `list_custom/` в `list/`
2. **download_antifilter_lists** — скачивает списки с antifilter.download/network (с экспоненциальной задержкой повторов)
3. **compare_and_update** — сравнивает скачанное с `list/`, обновляет при изменениях
4. **process_lists** — валидирует CIDR (IPv4 + IPv6) и конвертирует `.lst` в `.rsc` (`route IP/CIDR unreachable;`)
5. **apply_blacklist** — удаляет маршруты, попадающие под `black_list/`
6. **resolve_overlaps** — обнаруживает и удаляет перекрывающиеся супернеты
7. **generate_bird_conf** — заполняет `bird.conf.template` и сохраняет в `bird.conf`

Каждый запуск завершается **статистическим отчётом** (кол-во скачанных списков, невалидных CIDR, исключённых blacklist-маршрутов, удалённых перекрытий и общее число маршрутов).

### Переменные окружения

| Переменная | По умолчанию | Описание |
|------------|--------------|----------|
| `DNS1` | `77.88.8.8` | Основной DNS-сервер |
| `DNS2` | `77.88.8.1` | Резервный DNS-сервер |
| `SYNC_CRON` | `0 3 * * *` | Расписание синхронизации списков (cron-формат) |
| `MONITOR_CRON` | `*/10 * * * *` | Расписание мониторинга BGP-сессии (cron-формат) |

---

## Docker Compose

```yaml
services:
  bird2:
    build: .
    image: bird2-antifilter:latest
    container_name: bird2-antifilter
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./etc/bird/bird2.conf:/etc/bird/bird2.conf:ro
      - ./etc/bird/bird.conf.template:/etc/bird/bird.conf.template:ro
      - ./etc/bird/list_custom:/etc/bird/list_custom:ro
      - ./etc/bird/black_list:/etc/bird/black_list:ro
      - bird2-state:/var/run/bird
    cap_add:
      - NET_ADMIN
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: '1.0'
    healthcheck:
      test: ["CMD", "birdc", "show", "protocols"]
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 30s
    environment:
      - DNS1=77.88.8.8
      - DNS2=77.88.8.1
      - SYNC_CRON=0 3 * * *
      - MONITOR_CRON=*/10 * * * *

volumes:
  bird2-state:
    driver: local
```

---

## Автоматическая синхронизация

Cron запускает `bird2.sh` по расписанию `SYNC_CRON` (по умолчанию ежедневно в 03:00). При работающем BIRD2 конфиг валидируется и перезагружается автоматически (`birdc configure`). Лог синхронизации ротируется еженедельно.

## BGP-мониторинг

По расписанию `MONITOR_CRON` (по умолчанию каждые 10 минут) запускается режим мониторинга: `/bin/bird2.sh monitor`. Он проверяет:

- Состояние BGP-пиров — алерт, если пир не в состоянии `Established`
- Количество маршрутов — алерт, если оно упало ниже порога `min_routes` из `bird2.conf`

Чтобы не спамить, повторные алерты подавляются в течение 15 минут. Запустить мониторинг вручную:

```bash
docker exec bird2-antifilter /bin/bird2.sh monitor
```

---

## Траблшутинг

### Логи контейнера

```bash
docker logs bird2-antifilter
```

### Войти в контейнер

```bash
docker exec -it bird2-antifilter bash
```

### Статус BIRD2

```bash
docker exec bird2-antifilter birdc show protocols
docker exec bird2-antifilter birdc show route count
```

### Проверить сгенерированный конфиг

```bash
docker exec bird2-antifilter cat /etc/bird/bird.conf
```

### Проверить .rsc файлы

```bash
docker exec bird2-antifilter ls -la /etc/bird/list_rsc/
docker exec bird2-antifilter head -5 /etc/bird/list_rsc/allyouneed.rsc
```

### Ручной запуск синхронизации

```bash
docker exec bird2-antifilter /bin/bird2.sh
```

---

## Требования

- MikroTik RouterOS с поддержкой Containers
- Docker (для сборки)
- Доступ к antifilter.download / antifilter.network из контейнера

---

## Версии

| Версия | Описание |
|--------|----------|
| v3.1.0 | Безопасность (без privileged), валидация конфига, IPv6, blacklist на awk, healthcheck, graceful shutdown, BGP-мониторинг, настраиваемый cron, Release-публикация |
| v3.0 | Валидация CIDR, папка black_list, разрешение перекрытий, шаблон `bird.conf.template` |
| v2.0 | Первый релиз |
