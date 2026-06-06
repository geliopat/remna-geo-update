# remna-geo-update

Автообновление `geoip.dat` и `geosite.dat` для ноды **Remnawave** (`remnanode`) из
релизов проекта **roscomvpn** (hydraponique). Проверка раз в сутки ночью, замена и
перезапуск ноды — **только если файл реально изменился**.

Источники списков:
- [roscomvpn-geoip](https://github.com/hydraponique/roscomvpn-geoip) — `geoip.dat`
- [roscomvpn-geosite](https://github.com/hydraponique/roscomvpn-geosite) — `geosite.dat`
- [roscomvpn-routing](https://github.com/hydraponique/roscomvpn-routing) — профили роутинга

Рассчитан на ноду, установленную скриптом
[DigneZzZ/remnawave-scripts → `remnanode.sh`](https://github.com/DigneZzZ/remnawave-scripts),
который монтирует гео-файлы так:

```yaml
volumes:
  - /var/lib/remnanode/geoip.dat:/usr/local/share/xray/geoip.dat
  - /var/lib/remnanode/geosite.dat:/usr/local/share/xray/geosite.dat
```

## Установка одной строкой

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Agellar/remna-geo-update/main/remna-geo-update.sh) install
```

Команда скопирует скрипт в `/usr/local/bin/remna-geo-update.sh`, поднимет ночной
systemd-таймер (а если systemd нет — задание в `cron`) и сразу выполнит первое
обновление.

## Что делает

- Качает `geoip.dat` / `geosite.dat` со стабильных `releases/latest/download/…`.
- Кладёт туда, куда их монтирует `remnanode.sh` — по умолчанию
  `/var/lib/remnanode/{geoip,geosite}.dat`. Реальный путь **автоопределяется** из
  `/opt/remnanode/docker-compose.yml`, дефолт — лишь запасной вариант.
- Раз в сутки ночью (`OnCalendar=*-*-* 04:00:00` + случайный разброс до 30 мин,
  `Persistent=true`) сверяет свежий файл с текущим байт-в-байт.
- При изменении атомарно подменяет файл, ставит права `root:root` `0644`
  (world-readable → читается xray под любым UID в контейнере) и **перезапускает
  ноду**, чтобы Xray перечитал гео-данные.
- Если изменений нет — контейнер не трогается.

> **Почему нужен перезапуск.** Монтируется *отдельный файл* (привязка к inode), а
> Xray читает гео-данные только на старте. Без рестарта запущенный контейнер новый
> файл не подхватит, поэтому скрипт делает `docker compose restart` (или
> `docker restart`) — но лишь когда файл изменился.

## Команды

```bash
sudo remna-geo-update.sh update      # обновить сейчас (это же дёргает таймер)
sudo remna-geo-update.sh status      # конфиг, файлы, состояние таймера, хвост лога
sudo remna-geo-update.sh uninstall   # снять таймер/cron и удалить скрипт
sudo remna-geo-update.sh help        # справка
```

Лог: `/var/log/remna-geo-update.log`. Под systemd также `journalctl -u remna-geo-update`.

## Конфигурация

Переменными окружения или файлом `/etc/remna-geo-update.conf`:

```bash
RESTART_ON_CHANGE=false               # не перезапускать ноду автоматически
TIMER_CALENDAR="*-*-* 03:30:00"       # другое время запуска
CONTAINER=remnanode                   # имя контейнера, если отличается
DATA_DIR=/var/lib/remnanode           # каталог с гео-файлами
COMPOSE_FILE=/opt/remnanode/docker-compose.yml
GEOIP_URL=...                         # свой источник geoip.dat
GEOSITE_URL=...                       # свой источник geosite.dat
```

Если в `docker-compose.yml` нет монтирования гео-файлов, скрипт это заметит и
подскажет в логе, какие строки добавить (иначе нода использует встроенные в образ
списки).

## Лицензия

[MIT](LICENSE)
