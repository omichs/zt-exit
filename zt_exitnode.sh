#!/usr/bin/env bash
# zt_exitnode.sh — настройка Linux-сервера как exit-node для ZeroTier
# Совместимость: Ubuntu 20.04+ / Debian 11+
# Требования: root, zerotier-one установлен и узел авторизован в сети
set -euo pipefail

# ─── Проверки ────────────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || { echo "Ошибка: запустите скрипт от root (sudo)"; exit 1; }

if ! command -v zerotier-cli &>/dev/null; then
    echo "Ошибка: zerotier-one не установлен"
    echo "Установка: curl -s https://install.zerotier.com | bash"
    exit 1
fi

# ─── Определение интерфейсов ─────────────────────────────────────────────────

WAN_IF=$(ip route show default | awk '/default/ {print $5; exit}')
if [[ -z "$WAN_IF" ]]; then
    echo "Ошибка: не удалось определить WAN-интерфейс (нет маршрута по умолчанию)"
    exit 1
fi

# Ищем все ZT-интерфейсы; если их несколько — просим уточнить
mapfile -t ZT_IFS < <(ip -o link show | awk -F': ' '$2 ~ /^zt/ {print $2}')
if [[ ${#ZT_IFS[@]} -eq 0 ]]; then
    echo "Ошибка: ZeroTier-интерфейс не найден."
    echo "Убедитесь, что узел авторизован в сети и zerotier-one запущен:"
    echo "  sudo systemctl status zerotier-one"
    echo "  sudo zerotier-cli listnetworks"
    exit 1
fi
if [[ ${#ZT_IFS[@]} -gt 1 ]]; then
    echo "Обнаружено несколько ZeroTier-интерфейсов: ${ZT_IFS[*]}"
    read -rp "Введите имя нужного интерфейса: " ZT_IF
    # Проверяем, что введённое имя реально существует
    ip link show "$ZT_IF" &>/dev/null || { echo "Ошибка: интерфейс '$ZT_IF' не найден"; exit 1; }
else
    ZT_IF="${ZT_IFS[0]}"
fi

echo "WAN-интерфейс : $WAN_IF"
echo "ZT-интерфейс  : $ZT_IF"

# ─── 1. IPv4 forwarding ───────────────────────────────────────────────────────

echo "[1] Включаем IPv4 forwarding..."
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-zt-forward.conf
sysctl -q -p /etc/sysctl.d/99-zt-forward.conf

# ─── 2. iptables ─────────────────────────────────────────────────────────────

echo "[2] Настраиваем iptables..."

# NAT: подменяем src-IP клиентов на IP сервера при выходе в WAN
iptables -t nat -C POSTROUTING -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -o "$WAN_IF" -j MASQUERADE

# Пропускаем ответный трафик (RELATED/ESTABLISHED) — без привязки к интерфейсу,
# как рекомендует официальная документация ZeroTier
iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# Пропускаем исходящий трафик клиентов: ZT → WAN
iptables -C FORWARD -i "$ZT_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$ZT_IF" -o "$WAN_IF" -j ACCEPT

# ─── 3. nftables (Ubuntu 24.04 с iptables-nft backend) ───────────────────────

if command -v nft &>/dev/null && nft list ruleset 2>/dev/null | grep -q "hook postrouting"; then
    echo "[2a] Обнаружен активный nftables postrouting — добавляем правило..."
    nft add table ip zt_nat 2>/dev/null || true
    nft add chain ip zt_nat postrouting \
        '{ type nat hook postrouting priority srcnat; }' 2>/dev/null || true
    # Проверяем наличие правила перед добавлением, чтобы не задваивать
    if ! nft list chain ip zt_nat postrouting 2>/dev/null | grep -q "oif \"$WAN_IF\" masquerade"; then
        nft add rule ip zt_nat postrouting oif "$WAN_IF" masquerade
    fi
fi

# ─── 4. Сохранение правил ────────────────────────────────────────────────────

echo "[3] Сохраняем правила (iptables-persistent)..."
export DEBIAN_FRONTEND=noninteractive
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections

if ! dpkg -s iptables-persistent &>/dev/null; then
    apt-get -qq update
    apt-get -qq install -y iptables-persistent
fi

netfilter-persistent save

# ─── Готово ──────────────────────────────────────────────────────────────────

ZT_IP=$(zerotier-cli listnetworks 2>/dev/null | awk 'NR>1 {split($NF,a,"/"); print a[1]; exit}')

echo ""
echo "Настройка завершена."
echo ""
echo "Дальнейшие шаги в ZeroTier Central (my.zerotier.com):"
echo "  1. Откройте вашу сеть → вкладка Settings → Managed Routes."
if [[ -n "$ZT_IP" ]]; then
    echo "  2. Добавьте маршрут: 0.0.0.0/0 via $ZT_IP"
else
    echo "  2. Добавьте маршрут: 0.0.0.0/0 via <ZT-IP этого сервера>"
    echo "     (ZT-IP можно найти командой: sudo zerotier-cli listnetworks)"
fi
echo ""
echo "На клиентских устройствах:"
echo "  Linux:   sudo zerotier-cli set <NETWORK_ID> allowDefault=1"
echo "  Windows/macOS/iOS/Android: включите 'Route all traffic' в приложении ZeroTier."
echo ""
echo "Проверка: убедитесь, что внешний IP совпадает с IP этого сервера."
