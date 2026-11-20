#!/bin/sh
# tg-keenetic-lite — ПОЛНОЕ бесследное удаление.
#
# Снимает всё, что ставил install.sh:
#   1. Останавливает сервис (S99tg-proxy stop + добивает осиротевшие процессы).
#   2. Снимает ВСЕ iptables/ipset-правила и ипсеты модуля.
#   3. Удаляет NDM-хук, init-скрипт, бинарник, конфиг/списки, логи.
# После запуска роутер остаётся 100% чистым (iptables/ipset без следов модуля).

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "Запустите от root."; exit 1; }
echo "tg-keenetic-lite: удаление..."

# --- 1. Остановка сервиса ------------------------------------------------------
[ -x /opt/etc/init.d/S99tg-proxy ] && /opt/etc/init.d/S99tg-proxy stop >/dev/null 2>&1

# Страховка: осиротевшие надзиратели/демоны (ppid=1), не убитые stop'ом.
for _pd in /proc/[0-9]*; do
    p="${_pd#/proc/}"
    [ "$p" = "$$" ] && continue
    [ -r "$_pd/cmdline" ] || continue
    _cl=$(tr '\0' ' ' < "$_pd/cmdline" 2>/dev/null)
    case "$_cl" in
        *S99tg-proxy*|*tg-mtproxy-client*)
            [ "$(awk '/^PPid:/{print $2}' "$_pd/status" 2>/dev/null)" = "1" ] && kill "$p" 2>/dev/null
            ;;
    esac
done
sleep 1
# Демон всё ещё держит :1443?
if pidof tg-mtproxy-client >/dev/null 2>&1; then
    for p in $(pidof tg-mtproxy-client); do
        [ -r "/proc/$p/cmdline" ] || continue
        if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q -- "--listen=:1443"; then
            kill -9 "$p" 2>/dev/null
        fi
    done
fi

# --- 2. Правила и ипсеты -------------------------------------------------------
LIB=/opt/etc/tg-proxy/tg-redirect.sh
if [ -r "$LIB" ]; then
    . "$LIB"
    tgl_remove_all 2>/dev/null   # v4 REDIRECT + v6 REJECT + destroy ipset
else
    # Lib отсутствует — снимаем вручную, на всякий случай.
    _s="tgl_dc"
    while iptables -t nat -C PREROUTING -p tcp --dport 443 -m set --match-set "$_s" dst -j REDIRECT --to-port 1443 2>/dev/null; do
        iptables -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set "$_s" dst -j REDIRECT --to-port 1443 2>/dev/null || break
    done
    while iptables -t nat -C OUTPUT -p tcp --dport 443 -m set --match-set "$_s" dst -j REDIRECT --to-port 1443 2>/dev/null; do
        iptables -t nat -D OUTPUT -p tcp --dport 443 -m set --match-set "$_s" dst -j REDIRECT --to-port 1443 2>/dev/null || break
    done
    _i6="tgl_dc6"
    while ip6tables -C FORWARD -p tcp -m set --match-set "$_i6" dst -j REJECT --reject-with tcp-reset 2>/dev/null; do
        ip6tables -D FORWARD -p tcp -m set --match-set "$_i6" dst -j REJECT --reject-with tcp-reset 2>/dev/null || break
    done
    while ip6tables -C OUTPUT -p tcp -m set --match-set "$_i6" dst -j REJECT --reject-with tcp-reset 2>/dev/null; do
        ip6tables -D OUTPUT -p tcp -m set --match-set "$_i6" dst -j REJECT --reject-with tcp-reset 2>/dev/null || break
    done
    ipset destroy tgl_dc  2>/dev/null || true
    ipset destroy tgl_dc6 2>/dev/null || true
fi
# conntrack: сброс, чтобы клиенты сразу уехали в прямой эфир.
command -v conntrack >/dev/null 2>&1 && conntrack -F 2>/dev/null || true

# --- 3. Файлы -------------------------------------------------------------------
rm -f /opt/etc/ndm/netfilter.d/95-tg-proxy.sh
rm -f /opt/etc/init.d/S99tg-proxy
rm -f /opt/sbin/tg-mtproxy-client
rm -rf /opt/etc/tg-proxy
rm -f /var/run/tg-proxy.pid /var/run/tg-proxy.gen
rm -f /tmp/tg-proxy.log

# --- 4. Контроль чистоты --------------------------------------------------------
_rc=0
if ipset list 2>/dev/null | grep -q "^Name: tgl_dc"; then
    echo "ВНИМАНИЕ: ипсет tgl_dc всё ещё на месте (ядро занято?)"; _rc=1
fi
if iptables -t nat -S 2>/dev/null | grep -q "tgl_dc"; then
    echo "ВНИМАНИЕ: в nat-таблице остались правила tgl_dc"; _rc=1
fi
if [ -e /opt/sbin/tg-mtproxy-client ] || [ -d /opt/etc/tg-proxy ] || [ -e /opt/etc/init.d/S99tg-proxy ]; then
    echo "ВНИМАНИЕ: остались файлы модуля"; _rc=1
fi
if [ "$_rc" = "0" ]; then
    echo "tg-keenetic-lite удалён полностью: файлы, правила, ипсеты, хуки — чисто."
fi
exit $_rc
