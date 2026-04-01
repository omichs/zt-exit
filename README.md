# zt_exit

Bash-скрипт для быстрой настройки Linux-сервера как **exit-node для ZeroTier** — все участники вашей ZeroTier-сети смогут направлять интернет-трафик через этот сервер.

## Что делает скрипт

- Включает `ip_forward` постоянно (через `/etc/sysctl.d/`)
- Настраивает NAT (`iptables MASQUERADE`) и правила `FORWARD`
- Корректно обрабатывает системы с `nftables` backend (Ubuntu 24.04+)
- Сохраняет правила через `iptables-persistent` (переживают перезагрузку)
- Идемпотентен — безопасно запускать повторно

## Требования

| | |
|---|---|
| ОС | Ubuntu 20.04+ / Debian 11+ |
| Права | root |
| Зависимости | `zerotier-one` установлен, узел **авторизован** в сети |

## Установка и запуск

```bash
curl -fsSL https://raw.githubusercontent.com/omichs/zt-exit/main/zt_exitnode.sh | sudo bash
```

Или вручную:

```bash
wget https://raw.githubusercontent.com/omichs/zt-exit/main/zt_exitnode.sh
chmod +x zt_exitnode.sh
sudo ./zt_exitnode.sh
```

## После запуска

1. Откройте [ZeroTier Central](https://my.zerotier.com) → ваша сеть → **Settings → Managed Routes**
2. Добавьте маршрут: `0.0.0.0/0` via `<ZT-IP этого сервера>`  
   *(скрипт выведет нужный IP автоматически)*
3. На клиентах включите маршрутизацию через exit-node:

   | Платформа | Способ |
   |---|---|
   | Linux | `sudo zerotier-cli set <NETWORK_ID> allowDefault=1` |
   | Windows / macOS | Включите **Route all traffic** в приложении ZeroTier |
   | iOS / Android | Включите **Route all traffic** в приложении ZeroTier |

## Проверка

```bash
# Убедитесь, что правила применились
sudo iptables -t nat -L POSTROUTING -n -v
sudo iptables -L FORWARD -n -v

# Внешний IP клиента должен совпадать с IP сервера
curl ifconfig.me
```

## Устранение неполадок

**ZeroTier-интерфейс не найден**  
Убедитесь, что сервис запущен и узел авторизован:
```bash
sudo systemctl status zerotier-one
sudo zerotier-cli listnetworks
```

**Трафик не проходит после перезагрузки**  
Проверьте, что правила сохранились:
```bash
sudo iptables-save | grep -E "MASQUERADE|FORWARD"
```

**Несколько ZeroTier-сетей**  
Скрипт обнаружит несколько `zt`-интерфейсов и предложит выбрать нужный.

## Лицензия

MIT
