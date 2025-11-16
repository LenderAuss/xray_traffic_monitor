#!/bin/bash

# Улучшенный скрипт мониторинга Xray с уникальными IP

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Функция для форматирования байтов в GB
format_bytes_gb() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0.00"
        return
    fi
    echo "scale=2; $bytes / 1073741824" | bc 2>/dev/null || echo "0.00"
}

# Функция для инициализации счётчиков iptables
init_traffic_counters() {
    if ! iptables -L XRAY_TRAFFIC -n &>/dev/null; then
        iptables -N XRAY_TRAFFIC 2>/dev/null
        
        local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json 2>/dev/null))
        
        for port in "${ports[@]}"; do
            iptables -A XRAY_TRAFFIC -p tcp --dport $port
            iptables -A XRAY_TRAFFIC -p tcp --sport $port
        done
        
        if ! iptables -C INPUT -j XRAY_TRAFFIC &>/dev/null; then
            iptables -I INPUT -j XRAY_TRAFFIC
        fi
        if ! iptables -C OUTPUT -j XRAY_TRAFFIC &>/dev/null; then
            iptables -I OUTPUT -j XRAY_TRAFFIC
        fi
    fi
}

# Функция для получения трафика через iptables
get_traffic_iptables() {
    local port=$1
    local direction=$2
    
    if [ "$direction" = "in" ]; then
        iptables -L XRAY_TRAFFIC -n -v -x 2>/dev/null | grep "dpt:$port" | awk '{sum+=$2} END {print sum}'
    else
        iptables -L XRAY_TRAFFIC -n -v -x 2>/dev/null | grep "spt:$port" | awk '{sum+=$2} END {print sum}'
    fi
}

# Функция для получения уникальных IP адресов для порта
get_unique_ips() {
    local port=$1
    
    # Получаем все соединения для порта, извлекаем IP (без портов)
    # Используем ss для IPv4 и IPv6
    ss -tn 2>/dev/null | grep ":$port " | awk '{print $5}' | sed 's/::ffff://g' | cut -d: -f1 | sort -u | wc -l
}

# Функция для получения активных соединений
get_active_connections() {
    local port=$1
    ss -tn 2>/dev/null | grep ":$port " | grep ESTAB | wc -l
}

# Функция для отображения статистики в табличном формате
show_enhanced_traffic() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              📊 РАСШИРЕННАЯ СТАТИСТИКА ТРАФИКА XRAY                           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    init_traffic_counters
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    if [ ${#ports[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: не найдены порты в конфигурации${NC}"
        return 1
    fi
    
    # Заголовок таблицы
    printf "${BLUE}%-15s${NC} ${GREEN}%-8s${NC} ${YELLOW}%-12s${NC} ${MAGENTA}%-12s${NC} ${CYAN}%-12s${NC}\n" \
        "Пользователь" "Порт" "Всего GB" "Уник. IP" "Акт. конн."
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    local total_bytes=0
    local total_unique_ips=0
    local total_connections=0
    
    # Массив для хранения данных (для сортировки)
    declare -a user_data
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        local total=$(echo "$bytes_in + $bytes_out" | bc 2>/dev/null || echo "0")
        local total_gb=$(format_bytes_gb "$total")
        
        local unique_ips=$(get_unique_ips "$port")
        local active_conns=$(get_active_connections "$port")
        
        total_bytes=$(echo "$total_bytes + $total" | bc 2>/dev/null || echo "0")
        total_unique_ips=$(echo "$total_unique_ips + $unique_ips" | bc 2>/dev/null || echo "0")
        total_connections=$(echo "$total_connections + $active_conns" | bc 2>/dev/null || echo "0")
        
        # Цветной вывод в зависимости от активности
        if [ "$active_conns" -gt 0 ]; then
            printf "${GREEN}%-15s${NC} %-8s ${YELLOW}%-12s${NC} ${MAGENTA}%-12s${NC} ${CYAN}%-12s${NC}\n" \
                "$tag" "$port" "$total_gb" "$unique_ips" "$active_conns"
        else
            printf "%-15s %-8s %-12s %-12s %-12s\n" \
                "$tag" "$port" "$total_gb" "$unique_ips" "$active_conns"
        fi
    done
    
    # Итоговая строка
    echo "────────────────────────────────────────────────────────────────────────────────"
    local total_gb=$(format_bytes_gb "$total_bytes")
    printf "${YELLOW}%-15s${NC} %-8s ${GREEN}%-12s${NC} ${MAGENTA}%-12s${NC} ${CYAN}%-12s${NC}\n" \
        "ИТОГО:" "-" "$total_gb" "$total_unique_ips" "$total_connections"
    echo ""
}

# Функция для JSON формата (для ботов/API)
export_json() {
    local output_file="${1:-/tmp/xray_stats.json}"
    
    init_traffic_counters
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    local timestamp=$(date -Iseconds)
    
    echo "{" > "$output_file"
    echo "  \"timestamp\": \"$timestamp\"," >> "$output_file"
    echo "  \"users\": [" >> "$output_file"
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        local total=$(echo "$bytes_in + $bytes_out" | bc)
        local total_gb=$(format_bytes_gb "$total")
        
        local unique_ips=$(get_unique_ips "$port")
        local active_conns=$(get_active_connections "$port")
        
        echo "    {" >> "$output_file"
        echo "      \"user\": \"$tag\"," >> "$output_file"
        echo "      \"port\": $port," >> "$output_file"
        echo "      \"traffic_bytes\": $total," >> "$output_file"
        echo "      \"traffic_gb\": $total_gb," >> "$output_file"
        echo "      \"unique_ips\": $unique_ips," >> "$output_file"
        echo "      \"active_connections\": $active_conns" >> "$output_file"
        
        if [ $i -lt $((${#ports[@]} - 1)) ]; then
            echo "    }," >> "$output_file"
        else
            echo "    }" >> "$output_file"
        fi
    done
    
    echo "  ]" >> "$output_file"
    echo "}" >> "$output_file"
    
    echo -e "${GREEN}✓ JSON экспортирован в $output_file${NC}"
    echo ""
    echo "Содержимое:"
    cat "$output_file" | jq '.' 2>/dev/null || cat "$output_file"
}

# Функция для формата готового к отправке в Telegram
export_telegram_format() {
    init_traffic_counters
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "📊 *Статистика Xray VPN*"
    echo "🕐 $timestamp"
    echo ""
    echo "\`\`\`"
    printf "%-12s %8s %10s %8s\n" "User" "Port" "Traffic" "IPs"
    echo "─────────────────────────────────────────────"
    
    local total_bytes=0
    local total_ips=0
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        local total=$(echo "$bytes_in + $bytes_out" | bc)
        local total_gb=$(format_bytes_gb "$total")
        
        local unique_ips=$(get_unique_ips "$port")
        
        total_bytes=$(echo "$total_bytes + $total" | bc)
        total_ips=$(echo "$total_ips + $unique_ips" | bc)
        
        printf "%-12s %8s %9s GB %5s\n" "$tag" "$port" "$total_gb" "$unique_ips"
    done
    
    echo "─────────────────────────────────────────────"
    local grand_total=$(format_bytes_gb "$total_bytes")
    printf "%-12s %8s %9s GB %5s\n" "ИТОГО" "-" "$grand_total" "$total_ips"
    echo "\`\`\`"
    
    echo ""
    echo "Скопируйте текст выше для отправки в Telegram"
    echo "(форматирование Markdown будет работать)"
}

# Функция для CSV формата (расширенный)
export_enhanced_csv() {
    local filename="${1:-traffic_enhanced_$(date +%Y%m%d_%H%M%S).csv}"
    
    init_traffic_counters
    
    echo "Timestamp,User,Port,Traffic_Bytes,Traffic_GB,Unique_IPs,Active_Connections" > "$filename"
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        local total=$(echo "$bytes_in + $bytes_out" | bc)
        local total_gb=$(format_bytes_gb "$total")
        
        local unique_ips=$(get_unique_ips "$port")
        local active_conns=$(get_active_connections "$port")
        
        echo "$timestamp,$tag,$port,$total,$total_gb,$unique_ips,$active_conns" >> "$filename"
    done
    
    echo -e "${GREEN}✓ Расширенный CSV экспортирован в $filename${NC}"
}

# Функция для SQL INSERT формата
export_sql_inserts() {
    local table_name="${1:-xray_traffic}"
    
    init_traffic_counters
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    echo "-- SQL INSERT statements для таблицы $table_name"
    echo "-- Timestamp: $timestamp"
    echo ""
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        local total=$(echo "$bytes_in + $bytes_out" | bc)
        local total_gb=$(format_bytes_gb "$total")
        
        local unique_ips=$(get_unique_ips "$port")
        local active_conns=$(get_active_connections "$port")
        
        echo "INSERT INTO $table_name (timestamp, username, port, traffic_bytes, traffic_gb, unique_ips, active_connections) VALUES ('$timestamp', '$tag', $port, $total, $total_gb, $unique_ips, $active_conns);"
    done
    
    echo ""
    echo "-- Конец SQL statements"
}

# Функция для детального отчёта с IP адресами
show_detailed_report() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    📋 ДЕТАЛЬНЫЙ ОТЧЁТ ПО ПОЛЬЗОВАТЕЛЯМ                        ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    init_traffic_counters
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        local total=$(echo "$bytes_in + $bytes_out" | bc)
        local total_gb=$(format_bytes_gb "$total")
        
        local unique_ips=$(get_unique_ips "$port")
        local active_conns=$(get_active_connections "$port")
        
        echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}👤 Пользователь:${NC} $tag"
        echo -e "${BLUE}🔌 Порт:${NC} $port"
        echo -e "${MAGENTA}📊 Трафик:${NC} $total_gb GB"
        echo -e "${CYAN}🌐 Уникальных IP:${NC} $unique_ips"
        echo -e "${GREEN}🔗 Активных соединений:${NC} $active_conns"
        
        if [ "$active_conns" -gt 0 ]; then
            echo ""
            echo -e "${YELLOW}📍 Подключённые IP адреса:${NC}"
            ss -tn 2>/dev/null | grep ":$port " | grep ESTAB | awk '{print $5}' | sed 's/::ffff://g' | cut -d: -f1 | sort -u | while read ip; do
                echo "   • $ip"
            done
        fi
        echo ""
    done
}

# Функция непрерывного мониторинга
watch_enhanced_traffic() {
    local interval=${1:-3}
    
    echo -e "${YELLOW}Непрерывный мониторинг (обновление каждые ${interval}с, Ctrl+C для выхода)${NC}"
    echo ""
    
    while true; do
        clear
        show_enhanced_traffic
        echo ""
        echo -e "${BLUE}Следующее обновление через ${interval}с...${NC}"
        sleep $interval
    done
}

# Главное меню
show_menu() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              📊 РАСШИРЕННЫЙ МОНИТОРИНГ ТРАФИКА XRAY                           ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo " 1) 📊 Показать статистику (таблица)"
    echo " 2) 📋 Детальный отчёт с IP адресами"
    echo " 3) 🔄 Непрерывный мониторинг"
    echo " 4) 📤 Экспорт в JSON (для ботов/API)"
    echo " 5) 💬 Формат для Telegram"
    echo " 6) 📑 Экспорт в CSV"
    echo " 7) 🗄️  SQL INSERT statements"
    echo " 8) 🔄 Сбросить счётчики"
    echo " 9) 🔧 Инициализировать счётчики"
    echo " 0) ❌ Выход"
    echo ""
    read -p "Выберите действие: " choice
    
    case $choice in
        1) show_enhanced_traffic ;;
        2) show_detailed_report ;;
        3) 
            read -p "Интервал обновления (сек, по умолчанию 3): " interval
            interval=${interval:-3}
            watch_enhanced_traffic $interval
            ;;
        4) 
            read -p "Имя файла JSON (Enter для /tmp/xray_stats.json): " filename
            export_json "${filename:-/tmp/xray_stats.json}"
            ;;
        5) export_telegram_format ;;
        6) 
            read -p "Имя файла CSV (Enter для автоматического): " filename
            export_enhanced_csv "$filename"
            ;;
        7) 
            read -p "Имя таблицы (по умолчанию xray_traffic): " table_name
            export_sql_inserts "${table_name:-xray_traffic}" > /tmp/xray_inserts.sql
            echo "SQL сохранён в /tmp/xray_inserts.sql"
            cat /tmp/xray_inserts.sql
            ;;
        8) 
            iptables -Z XRAY_TRAFFIC 2>/dev/null
            echo -e "${GREEN}✓ Счётчики сброшены${NC}"
            ;;
        9) init_traffic_counters && echo -e "${GREEN}✓ Счётчики инициализированы${NC}" ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
    
    if [ "$choice" != "3" ] && [ "$choice" != "0" ]; then
        echo ""
        read -p "Нажмите Enter для продолжения..."
        show_menu
    fi
}

# Проверка прав root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Запустите скрипт с правами root (sudo)${NC}"
    exit 1
fi

# Проверка наличия необходимых утилит
if ! command -v bc &> /dev/null; then
    echo -e "${YELLOW}Установка bc...${NC}"
    apt-get update && apt-get install -y bc
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}Ошибка: jq не установлен. Установите: apt install jq${NC}"
    exit 1
fi

# Если запущен с аргументом
if [ $# -gt 0 ]; then
    case "$1" in
        show|stats) show_enhanced_traffic ;;
        detailed|detail) show_detailed_report ;;
        watch|monitor) watch_enhanced_traffic ${2:-3} ;;
        json) export_json "${2:-/tmp/xray_stats.json}" ;;
        telegram|tg) export_telegram_format ;;
        csv) export_enhanced_csv "$2" ;;
        sql) export_sql_inserts "${2:-xray_traffic}" ;;
        reset) iptables -Z XRAY_TRAFFIC 2>/dev/null && echo "✓ Счётчики сброшены" ;;
        init) init_traffic_counters && echo "✓ Счётчики инициализированы" ;;
        *) 
            echo "Использование: $0 [show|detailed|watch|json|telegram|csv|sql|reset|init]"
            echo ""
            echo "Примеры:"
            echo "  $0 show              - показать статистику"
            echo "  $0 detailed          - детальный отчёт с IP"
            echo "  $0 watch 5           - мониторинг каждые 5 сек"
            echo "  $0 json output.json  - экспорт в JSON"
            echo "  $0 telegram          - формат для Telegram"
            echo "  $0 csv report.csv    - экспорт в CSV"
            echo "  $0 sql table_name    - SQL INSERT statements"
            exit 1
            ;;
    esac
else
    # Интерактивное меню
    show_menu
fi
