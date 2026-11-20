#!/bin/sh
# tg-keenetic-lite — установка.
#
# Transparent Telegram bypass для Keenetic (Entware):
#   bin/<arch>/tg-mtproxy-client -> /opt/sbin/tg-mtproxy-client (слушает :1443)
#   ipset + iptables REDIRECT    -> весь TG-трафик DC (TCP 443) сети на :1443
#   NDM hook + S99tg-proxy       -> правила переживают reboot/reconnect WAN
#
# Zero-config: никаких секретов, токенов и relay-URL вводить не нужно.
# POSIX sh (BusyBox ash). Архитектура определяется ТОЛЬКО через uname -m —
# без od/awk-проб и без тестового запуска бинарника.

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

GITHOST1="https://raw.githubusercontent.com/Vikorikus/tg-keenetic-lite/main"
GITHOST2="https://cdn.jsdelivr.net/gh/Vikorikus/tg-keenetic-lite@main"
BINNAME="tg-mtproxy-client"

# --- 0. Права ----------------------------------------------------------------
[ "$(id -u 2>/dev/null)" = "0" ] || { echo "Запустите от root (Entware: opkg/ssh как root)."; exit 1; }
[ -d /opt ] || { echo "Entware не найден (/opt отсутствует)."; exit 1; }

# --- 1. Архитектура: только uname -m ------------------------------------------
_m=$(uname -m)
case "$_m" in
    aarch64|arm64)            ARCH="aarch64" ;;
    armv7*|armv6*|arm*|armel) ARCH="armv7" ;;
    mips-bigendian)           ARCH="mips" ;;
    mips|mipsel|mipsle|*mipsel*)
        # На Keenetic (MT7628/MT7621/EN75xx и др.) uname -m часто отдаёт "mips"
        # при little-endian ядре, поэтому по умолчанию берём mipsel.
        ARCH="mipsel"
        ;;
    *) echo "Неподдерживаемая архитектура: '$_m' (ожидается mipsel/mips/armv7/aarch64)"; exit 1 ;;
esac
echo "Архитектура: $_m -> bin/$ARCH"

# --- 2. Каталог источника ------------------------------------------------------
SRC=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
[ -n "$SRC" ] || SRC="."

# --- 3. Бинарник: локальный (repo) или скачиваем только свою арку --------------
BINLOCAL="$SRC/bin/$ARCH/$BINNAME"
TMPBIN=""
if [ -f "$BINLOCAL" ] && [ -s "$BINLOCAL" ]; then
    BINRESOLVED="$BINLOCAL"
else
    echo "Локальный бинарник не найден — качаю bin/$ARCH/$BINNAME с GitHub..."
    TMPBIN="/tmp/$BINNAME.dl.$$"
    _ok=0
    _url1="$GITHOST1/bin/$ARCH/$BINNAME"
    _url2="$GITHOST2/bin/$ARCH/$BINNAME"
    wget -q -O "$TMPBIN" "$_url1" 2>/dev/null && _ok=1
    [ "$_ok" = "1" ] || { wget -q -O "$TMPBIN" "$_url2" 2>/dev/null && _ok=1; }
    if [ "$_ok" != "1" ] || [ ! -s "$TMPBIN" ]; then
        rm -f "$TMPBIN"
        echo "Не удалось скачать бинарник для арки '$ARCH'."
        echo "  Попробуйте вручную:  wget -O /opt/sbin/$BINNAME $_url1"
        exit 1
    fi
    BINRESOLVED="$TMPBIN"
fi
# Бинарник ~6-7 МБ: урезанная/пустая загрузка (HTML-страница и т.п.) ловится по размеру.
_bs=$(wc -c < "$BINRESOLVED" 2>/dev/null)
[ -n "$_bs" ] && [ "$_bs" -lt 1000000 ] && { echo "Файл бинарника подозрительно мал ($_bs bytes) — отказываюсь."; [ -n "$TMPBIN" ] && rm -f "$TMPBIN"; exit 1; }

# --- 4. Минимальные пакеты Entware (только если их нет) ------------------------
_pkg_ok=1
for _p in iptables ipset; do
    command -v "$_p" >/dev/null 2>&1 || {
        echo "Ставляю пакет: $_p"
        opkg install "$_p" >/dev/null 2>&1
        command -v "$_p" >/dev/null 2>&1 || _pkg_ok=0
    }
done
if [ "$_pkg_ok" != "1" ]; then
    echo "ОШИБКА: не удалось установить iptables/ipset через opkg. Установите вручную: opkg update && opkg install iptables ipset"
    [ -n "$TMPBIN" ] && rm -f "$TMPBIN"
    exit 1
fi
# conntrack — опционален (flush старых записей), не блокируем установку.
command -v conntrack >/dev/null 2>&1 || opkg install conntrack >/dev/null 2>&1 || true

# --- 5. Останавливаем старый экземпляр (идемпотентная переустановка) -----------
[ -x /opt/etc/init.d/S99tg-proxy ] && /opt/etc/init.d/S99tg-proxy stop >/dev/null 2>&1

# --- 6. Конфиг, списки и рабочая директория состояния ------------------------
mkdir -p /opt/etc/tg-proxy /opt/zapret2 || exit 1
chmod 755 /opt/zapret2 2>/dev/null || true
cp -f "$SRC/tg-redirect.sh"  /opt/etc/tg-proxy/tg-redirect.sh
cp -f "$SRC/95-tg-proxy.sh"  /opt/etc/tg-proxy/95-tg-proxy.sh
cp -f "$SRC/telegram_ips.txt"  /opt/etc/tg-proxy/telegram_ips.txt 2>/dev/null || true
cp -f "$SRC/telegram_ips6.txt" /opt/etc/tg-proxy/telegram_ips6.txt 2>/dev/null || true
chmod 755 /opt/etc/tg-proxy/tg-redirect.sh 2>/dev/null

# --- 7. Бинарник: /opt/sbin/ ----------------------------------------------------
cp -f "$BINRESOLVED" "/opt/sbin/$BINNAME.new" || exit 1
chmod 755 "/opt/sbin/$BINNAME.new" || exit 1
# Атомарная замена: если старое имя ещё занято процессом — mv всё равно сменит
# inode, работающий процесс живёт со старым, новый старт возьмёт новый файл.
mv -f "/opt/sbin/$BINNAME.new" "/opt/sbin/$BINNAME" || exit 1

# --- 8. Init-скрипт и NDM-хук ---------------------------------------------------
mkdir -p /opt/etc/init.d /opt/etc/ndm/netfilter.d
cp -f "$SRC/S99tg-proxy" /opt/etc/init.d/S99tg-proxy
chmod 755 /opt/etc/init.d/S99tg-proxy
cp -f "$SRC/95-tg-proxy.sh" /opt/etc/ndm/netfilter.d/95-tg-proxy.sh
chmod 755 /opt/etc/ndm/netfilter.d/95-tg-proxy.sh

# --- 9. Убираем временные файлы ДО запуска сервиса (освобождаем RAM-диск) ------
rm -f "$TMPBIN" 2>/dev/null
case "$SRC" in
    /tmp/tg-keenetic-lite*|/tmp/tgl*)
        rm -rf "$SRC" 2>/dev/null
        ;;
esac

# --- 10. Старт -------------------------------------------------------------------
/opt/etc/init.d/S99tg-proxy start
sleep 1
/opt/etc/init.d/S99tg-proxy status
echo ""
echo "Установка tg-keenetic-lite завершена."
echo "  Демон:      /opt/sbin/$BINNAME  (:1443)"
echo "  Правила:    ipset tgl_dc + 2x REDIRECT 443->:1443 (PREROUTING/OUTPUT)"
echo "  Управление: /opt/etc/init.d/S99tg-proxy {start|stop|restart|status}"
echo "  Удаление:   sh uninstall.sh (из каталога модуля) — снимает всё до чистого состояния"