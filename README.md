# tg-keenetic-lite

**Transparent-обход блокировки Telegram на всех Keenetic с Entware. Zero-config:
никаких ключей, секретов, токенов и relay-URL вводить не нужно.**

Вырезанный из [z2k](https://github.com/z2k) модуль Telegram-прокси:
локальный прозрачный прокси `tg-mtproxy-client` + ipset/iptables-редирект
адресов Telegram DC, так что Telegram работает **автоматически на всех
устройствах сети** (телефоны, ПК, планшеты) без какой-либо настройки на них.

## Как это работает

1. `install.sh` кладёт бинарник под свою архитекку в `/opt/sbin/tg-mtproxy-client`
   и запускает его на порту `:1443` (supervisor с автоперезапуском,
   `GODEBUG=asyncpreemptoff=1 GOGC=20 GOMEMLIMIT=20MiB` — безопасно для
   64–128 MB RAM MIPS-модели).
2. Модуль создаёт ipset `tgl_dc` (только IP-субнеты Telegram DC — ничего
   лишнего) и 2 правила `iptables -t nat REDIRECT --to-port 1443` в
   PREROUTING и OUTPUT: весь TCP 443 на адреса Telegram из сети и с самого
   роутера прозрачно уводится на локальный прокси.
3. IPv6 DC получают быстрый `REJECT tcp-reset` (иначе мобильные клиенты теряют
   ~8 с на мёртвые v6-коннекты).
4. NDM-хук `/opt/etc/ndm/netfilter.d/95-tg-proxy.sh` заново подставляет
   правила после КАЖДОЙ регенерации netfilter Keenetic (reboot, flap WAN,
   DHCP renew, hotplug) — обход переживает перезагрузки и переподключения.

Почему не нужны ключи/секреты: прокси — автономный, встроенный в бинарник
(собирается з2k-тулчейном со вшитыми параметрами), ничего с устройства не
спрашивает и никуда не подключается кроме роутера.

## Архитектуры (`bin/<arch>/`)

| Каталог | Арка Keenetic | Примеры |
|---|---|---|
| `bin/mipsel/` | mipsel (MIPS32 little-endian) | KN-1711, KN-1410, KN-1010, ... |
| `bin/mips/` | mips (big-endian) | редкие BE-модели |
| `bin/armv7/` | armv7 | Hopper, Giga (arm) |
| `bin/aarch64/` | aarch64 | Ultra, Peak, Speedter (a64) |

Определение арки в `install.sh` — **только `uname -m`**, статически,
без `od`/`awk`-проб и без тестового запуска бинарника.

## Куда что ставится (Entware `/opt/...`)

| Файл модуля | Куда кладётся |
|---|---|
| `bin/<arch>/tg-mtproxy-client` | `/opt/sbin/tg-mtproxy-client` |
| `S99tg-proxy` | `/opt/etc/init.d/S99tg-proxy` |
| `95-tg-proxy.sh` | `/opt/etc/ndm/netfilter.d/95-tg-proxy.sh` |
| `tg-redirect.sh`, `telegram_ips.txt`, `telegram_ips6.txt` | `/opt/etc/tg-proxy/` |

Логи: `/tmp/tg-proxy.log` (автовращение >256 KiB). PID: `/var/run/tg-proxy.pid`.

## Установка (прямо с GitHub)

**Вариант 1 — wget + unzip (полный пакет, ~7 МБ):**

```sh
cd /tmp && wget -q https://github.com/Vikorikus/tg-keenetic-lite/archive/refs/heads/main.zip -O tgl.zip && unzip -q -o tgl.zip && sh tg-keenetic-lite-main/install.sh
```

(если `unzip` нет: `opkg install unzip` — одна команда, остальное install.sh делает сам:
пакеты iptables/ipset, списки, хуки, старт. Временные каталоги в /tmp он сам удалит.)

**Вариант 2 — wget-only one-liner (минимум: install.sh + бинарник только своей арки):**

```sh
wget -qO /tmp/i.sh https://raw.githubusercontent.com/Vikorikus/tg-keenetic-lite/main/install.sh && sh /tmp/i.sh
```

`install.sh` сам определит архитекку по `uname -m` и докачает только
`bin/<arch>/tg-mtproxy-client`.

## Проверка работы

```sh
/opt/etc/init.d/S99tg-proxy status          # supervisor + демон + правила
iptables -t nat -S PREROUTING | grep 1443  # REDIRECT-правило
ipset list tgl_dc                           # список DC
netstat -tln | grep 1443                   # демон слушает
```

И главное — откройте Telegram на любом устройстве в сети: он должен
подключиться сам, без прокси в настройках.

## Управление

```sh
/opt/etc/init.d/S99tg-proxy start|stop|restart|status
tail /tmp/tg-proxy.log                     # лог (осторожно, tail -f держит fd)
```

## Полное бесследное удаление

```sh
sh uninstall.sh
```

Снимает сервис, **все** iptables/ipset-правила и ипсеты модуля, NDM-хук,
`/opt/etc/init.d/S99tg-proxy`, `/opt/sbin/tg-mtproxy-client`, `/opt/etc/tg-proxy/`,
логи и pid-файлы — роутер остаётся чистым. Финальная проверка: `ipset list`
и `iptables -t nat -S` не содержат `tgl_dc`.

## Совместимость / заметки

- **RAM 64–128 MB**: строгий POSIX sh, только TG-списки (без YouTube/Discord),
  лимиты Go-рантайма (`GOMEMLIMIT=20MiB`), лог с автовращением, временные
  файлы `/tmp` удаляются до старта демона.
- Если на роутере стоит полноценный **z2k** — отключите его TG-модуль
  (`TG_PROXY_USER_DISABLED=1`), иначе оба будут рваться на `:1443`.
- Обновление списка DC: правьте `/opt/etc/tg-proxy/telegram_ips{,6}.txt`
  и выполните `ipset flush tgl_dc && ipset flush tgl_dc6 && /opt/etc/init.d/S99tg-proxy restart`.

## Структура репозитория

```
tg-keenetic-lite/
├── bin/{mipsel,mips,armv7,aarch64}/tg-mtproxy-client   # бинарники из z2k
├── install.sh        # установка (uname -m -> bin/<arch>)
├── uninstall.sh      # полное бесследное удаление
├── S99tg-proxy       # init: start|stop|restart|status
├── 95-tg-proxy.sh    # NDM netfilter hook
├── tg-redirect.sh    # lib: ipset + iptables-правила (единый источник)
├── telegram_ips.txt  # v4 DC (AS62041/59930)
└── telegram_ips6.txt # v6 DC
```
