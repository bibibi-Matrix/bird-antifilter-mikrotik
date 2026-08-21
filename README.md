# BIRD2 Antifilter Container for MikroTik RouterOS

> **Дисклеймер:** Проект создан в ознакомительных целях. Автор не несёт ответственности за любые последствия использования данного программного обеспечения. Используйте на свой страх и риск.

Docker-контейнер с BIRD2 для экспорта антифильтрованных маршрутов в MikroTik RouterOS через BGP.

## Возможности

- Автоматическая загрузка IP-списков с antifilter.download и antifilter.network
- Индивидуальные переключатели для каждого списка в `bird2.conf`
- Поддержка пользовательских списков (custom lists) через mount
- Автоопределение Router ID и IP шлюза из маршрута по умолчанию
- Генерация `bird.conf` при каждом запуске
- Ежедневная автоматическая синхронизация списков (cron, 03:00)
- DNS: Yandex (77.88.8.8 / 77.88.8.1)

## Структура проекта

```
bird/
├── .github/workflows/build.yml   # GitHub Actions - сборка образа
├── Dockerfile                     # Alpine 3.22 + bird2
├── docker-compose.yml             # Конфигурация запуска
├── bin/
│   ├── bird2.sh                   # Основной скрипт синхронизации
│   └── entrypoint.sh              # Точка входа контейнера
└── etc/bird/
    ├── bird2.conf                 # Конфигурация источников списков
    ├── bird.conf                  # Справочный (генерируется при запуске)
    └── list_custom/               # Пользовательские списки
        ├── AWS-Amazon.lst
        ├── Cloudflare.lst
        ├── Discord.lst
        ├── Google.lst
        ├── Meta.lst
        ├── Openh264.lst
        ├── Telegram.lst
        └── WebNovel.lst
```

## Установка

### Способ 1: Скачать готовый образ

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

> **Примечание:** BIRD2 работает в режиме `passive on` — MikroTik инициирует BGP-подключение к контейнеру.

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

## Конфигурация bird2.conf

Файл `etc/bird/bird2.conf` монтируется в контейнер как read-only. Управляйте источниками списков:

```ini
# === Antifilter Sources ===
# Мастер-переключатель antifilter.download
antifilter_download=yes
# Мастер-переключатель antifilter.network
antifilter_network=no

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

## Пользовательские списки (Custom Lists)

Файлы `.lst` в папке `etc/bird/list_custom/` автоматически копируются в контейнер при каждом запуске. Все списки загружаются безусловно (переключатели не используются).

Формат файла — одна запись на строку:

```
# Комментарии через #
192.168.0.0/16
10.0.0.0/8
1.2.3.4
```

## How It Works

Контейнер при запуске выполняет 5 шагов:

1. **sync_custom_lists** — копирует все `.lst` из `list_custom/` в `list/`
2. **download_antifilter_lists** — скачивает списки с antifilter.download/network в `/tmp`
3. **compare_and_update** — сравнивает скачанное с `list/`, обновляет при изменениях
4. **process_lists** — конвертирует `.lst` в `.rsc` формат BIRD2 (`route IP/CIDR unreachable;`)
5. **generate_bird_conf** — генерирует `bird.conf` с одним `protocol static static_all`

## Автоматическая синхронизация

Cron запускает `bird2.sh` ежедневно в 03:00. При работающем BIRD2 конфиг перезагружается автоматически (`birdc configure`).

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

## Требования

- MikroTik RouterOS с поддержкой Containers
- Docker (для сборки)
- Доступ к antifilter.download / antifilter.network из контейнера
