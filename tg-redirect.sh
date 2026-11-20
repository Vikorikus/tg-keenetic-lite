#!/bin/sh
# /opt/etc/tg-proxy/tg-redirect.sh — единый источник правил REDIRECT для
# Telegram DC (модуль tg-keenetic-lite, вырезан из z2k).
#
# Считывается (source) тремя местами, чтобы форма правил всегда совпадала:
#   - /opt/etc/ndm/netfilter.d/95-tg-proxy.sh  (NDM-хук после каждого регенератора netfilter)
#   - /opt/etc/init.d/S99tg-proxy              (start/stop)
#
# Почему ipset + iptables -w (перенесено из z2k, "root fix"):
#   - NDM на Keenetic пересобирает таблицы iptables по каждому netfilter-событию
#     (boot, flap WAN, DHCP renew, hotplug) и выметает все правила, не принадлежащие NDM.
#     ipset при этом НЕТРОГАЕТ — поэтому список DC живёт в ипсете, а
#     перечислять нужно всего 2 правила REDIRECT (а не 10 по-CIDR).
#   - iptables -w: ожидает xtables-замок. Без него вставка, столкнувшаяся с
#     чанжем NDM, возвращает EBUSY и молча падает — задокументированная
#     причина "пропавших" правил. Keenetic/Entware iptables понимает голый -w,
#     но не "-w <timeout>", поэтому используем голый -w с фолбэком без замка.

TGL_SET="tgl_dc"
TGL_SET6="tgl_dc6"
TGL_PORT=1443

# Встроенный фолбэк-список (используется, только если файлы списков
# отсутствуют или пусты). Актуальные списки: /opt/etc/tg-proxy/telegram_ips{,6}.txt
TGL_CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
TGL_CIDRS6="2001:b28:f23c::/47 2001:b28:f23f::/48 2001:67c:4e8::/48 2a0a:f280:203::/48"

_tgl_ipt()  { iptables   -w "$@" 2>/dev/null || iptables   "$@" 2>/dev/null; }
_tgl_ipt6() { ip6tables  -w "$@" 2>/dev/null || ip6tables  "$@" 2>/dev/null; }

# Читаем CIDR-список из файла (комментарии/пустые строки игнорируем).
# $1=файл; результат в $TGL_CIDRS / $TGL_CIDRS6.
_tgl_load_cidrs() {
    [ -r /opt/etc/tg-proxy/telegram_ips.txt ] && \
        TGL_CIDRS=$(grep -v '^[[:space:]]*#' /opt/etc/tg-proxy/telegram_ips.txt 2>/dev/null | tr '\n' ' ')
    [ -n "$TGL_CIDRS" ] || TGL_CIDRS="149.154.160.0/20 91.108.4.0/22 91.108.8.0/22 91.108.12.0/22 91.108.16.0/22 91.108.20.0/22 91.108.56.0/22 91.105.192.0/23 95.161.64.0/20 185.76.151.0/24"
    [ -r /opt/etc/tg-proxy/telegram_ips6.txt ] && \
        TGL_CIDRS6=$(grep -v '^[[:space:]]*#' /opt/etc/tg-proxy/telegram_ips6.txt 2>/dev/null | tr '\n' ' ')
    [ -n "$TGL_CIDRS6" ] || TGL_CIDRS6="2001:b28:f23c::/47 2001:b28:f23f::/48 2001:67c:4e8::/48 2a0a:f280:203::/48"
}

# --- IPv4: ipset + 2 правила REDIRECT 443 -> :1443 ---

tgl_ensure_ipset() {
    _tgl_load_cidrs
    ipset create "$TGL_SET" hash:net -exist 2>/dev/null || return 1
    for _c in $TGL_CIDRS; do
        ipset add "$TGL_SET" "$_c" -exist 2>/dev/null
    done
    return 0
}

tgl_rule_present() {
    _tgl_ipt -t nat -C "$1" -p tcp --dport 443 -m set --match-set "$TGL_SET" dst -j REDIRECT --to-port "$TGL_PORT"
}

# Ставит оба REDIRECT-правила (PREROUTING — трафик LAN, OUTPUT — сам роутер)
# в ГОЛОВУ цепочек, чтобы они шли раньше цепочек _NDM_*.
tgl_ensure_rules() {
    tgl_ensure_ipset || return 1
    tgl_ensure_rules6   # best-effort; не блокирует v4
    _retry=0
    while [ "$_retry" -lt 3 ]; do
        tgl_rule_present PREROUTING || _tgl_ipt -t nat -I PREROUTING 1 -p tcp --dport 443 -m set --match-set "$TGL_SET" dst -j REDIRECT --to-port "$TGL_PORT"
        tgl_rule_present OUTPUT     || _tgl_ipt -t nat -I OUTPUT 1 -p tcp --dport 443 -m set --match-set "$TGL_SET" dst -j REDIRECT --to-port "$TGL_PORT"
        if tgl_rule_present PREROUTING && tgl_rule_present OUTPUT; then
            return 0
        fi
        _retry=$((_retry + 1))
        [ "$_retry" -lt 3 ] && sleep 1
    done
    return 1
}

tgl_remove_rules() {
    tgl_remove_rules6
    while tgl_rule_present PREROUTING; do
        _tgl_ipt -t nat -D PREROUTING -p tcp --dport 443 -m set --match-set "$TGL_SET" dst -j REDIRECT --to-port "$TGL_PORT" || break
    done
    while tgl_rule_present OUTPUT; do
        _tgl_ipt -t nat -D OUTPUT -p tcp --dport 443 -m set --match-set "$TGL_SET" dst -j REDIRECT --to-port "$TGL_PORT" || break
    done
}

# --- IPv6: быстрый REJECT (tcp-reset) Telegram DC ---
# Мостовой путь клиента — IPv4 (:1443). IPv6 DC Telegram в РФ заблокированы,
# но мобильный клиент при холодном соединении гоняет v4 и v6 параллельно и
# теряет до ~8 с на таймаут мёртвого v6 SYN. Мгновенный RST на роутере
# убирает эту задержку (перенесено из z2k, "mobile TG connects 10-60s").

tgl_ensure_ipset6() {
    _tgl_load_cidrs
    ipset create "$TGL_SET6" hash:net family inet6 -exist 2>/dev/null || return 1
    for _c in $TGL_CIDRS6; do
        ipset add "$TGL_SET6" "$_c" -exist 2>/dev/null
    done
    return 0
}

tgl_rule6_present() {
    _tgl_ipt6 -C "$1" -p tcp -m set --match-set "$TGL_SET6" dst -j REJECT --reject-with tcp-reset
}

tgl_ensure_rules6() {
    tgl_ensure_ipset6 || return 1
    _retry6=0
    while [ "$_retry6" -lt 3 ]; do
        tgl_rule6_present FORWARD || _tgl_ipt6 -I FORWARD 1 -p tcp -m set --match-set "$TGL_SET6" dst -j REJECT --reject-with tcp-reset
        tgl_rule6_present OUTPUT  || _tgl_ipt6 -I OUTPUT 1  -p tcp -m set --match-set "$TGL_SET6" dst -j REJECT --reject-with tcp-reset
        if tgl_rule6_present FORWARD && tgl_rule6_present OUTPUT; then
            return 0
        fi
        _retry6=$((_retry6 + 1))
        [ "$_retry6" -lt 3 ] && sleep 1
    done
    return 1
}

tgl_remove_rules6() {
    while tgl_rule6_present FORWARD; do
        _tgl_ipt6 -D FORWARD -p tcp -m set --match-set "$TGL_SET6" dst -j REJECT --reject-with tcp-reset || break
    done
    while tgl_rule6_present OUTPUT; do
        _tgl_ipt6 -D OUTPUT -p tcp -m set --match-set "$TGL_SET6" dst -j REJECT --reject-with tcp-reset || break
    done
}

# --- conntrack: сброс старых записей, чтобы клиенты сразу поехали через REDIRECT ---

tgl_flush_conntrack() {
    command -v conntrack >/dev/null 2>&1 || return 0
    _tgl_load_cidrs
    for _c in $TGL_CIDRS; do
        conntrack -D -d "$_c" 2>/dev/null || true
    done
    return 0
}

# --- полный разбор (uninstall): правила + сами ипсеты ---

tgl_remove_all() {
    tgl_remove_rules
    ipset destroy "$TGL_SET"  2>/dev/null || true
    ipset destroy "$TGL_SET6" 2>/dev/null || true
}
