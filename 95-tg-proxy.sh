#!/bin/sh
# /opt/etc/ndm/netfilter.d/95-tg-proxy.sh — Keenetic NDM hook (модуль tg-keenetic-lite).
#
# NDM вызывает ВСЕ скрипты в /opt/etc/ndm/netfilter.d/ после каждой
# регенерации netfilter-правил (boot, up/down WAN, hotplug, DHCP renew и т.п.)
# и при этом выметает правила, не принадлежащие NDM. Здесь мы заново
# подставляем REDIRECT Telegram DC — ровно ту же форму правил, что ставит
# S99tg-proxy (общий lib /opt/etc/tg-proxy/tg-redirect.sh).
#
# NDM передаёт env: type (iptables|ip6tables) и table (nat|filter|...).
# Нам нужны: iptables/nat (REDIRECT v4) и ip6tables/filter (REJECT v6).

export PATH=/opt/sbin:/opt/bin:/sbin:/usr/sbin:/bin:/usr/bin

[ "$type" = "iptables" ] || [ "$type" = "ip6tables" ] || exit 0
case "$table" in nat|filter) ;; *) exit 0 ;; esac

# Ставим правила только пока демон реально жив — иначе оставляем iptables
# чистыми: мёртвый REDIRECT уводит трафик в никуда, а без него работает
# прямой путь.
pidof tg-mtproxy-client >/dev/null 2>&1 || exit 0

LIB=/opt/etc/tg-proxy/tg-redirect.sh
[ -r "$LIB" ] || exit 0
. "$LIB"

if [ "$type" = "iptables" ]; then
    tgl_ensure_rules        # ipset + 2 REDIRECT, -w, verify-retry
else
    tgl_ensure_rules6       # v6 fast-REJECT (FORWARD + OUTPUT)
fi

exit 0
