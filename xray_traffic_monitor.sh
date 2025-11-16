#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Функция для форматирования байтов в читаемый формат
format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0 B"
        return
    fi
    
    local kb=$(echo "scale=2; $bytes / 1024" | bc 2>/dev/null || echo "0")
    local mb=$(echo "scale=2; $bytes / 1024 / 1024" | bc 2>/dev/null || echo "0")
    local gb=$(echo "scale=2; $bytes / 1024 / 1024 / 1024" | bc 2>/dev/null || echo "0")
    
    if (( $(echo "$gb >= 1" | bc -l 2>/dev/null || echo "0") )); then
        echo "${gb} GB"
    elif (( $(echo "$mb >= 1" | bc -l 2>/dev/null || echo "0") )); then
        echo "${mb} MB"
    elif (( $(echo "$kb >= 1" | bc -l 2>/dev/null || echo "0") )); then
        echo "${kb} KB"
    else
        echo "${bytes} B"
    fi
}

# Функция для инициализации счётчиков iptables
init_traffic_counters() {
    echo -e "${YELLOW}Инициализация счётчиков трафика...${NC}"
    
    # Проверяем существование цепи
    if ! iptables -L XRAY_TRAFFIC -n &>/dev/null; then
        # Создаём цепь для отслеживания
        iptables -N XRAY_TRAFFIC 2>/dev/null
        
        # Получаем все порты из конфига Xray
        local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json 2>/dev/null))
        
        if [ ${#ports[@]} -eq 0 ]; then
            echo -e "${RED}Ошибка: не найдены порты в конфигурации Xray${NC}"
            return 1
        fi
        
        # Добавляем правила для каждого порта
        for port in "${ports[@]}"; do
            # Входящий трафик
            iptables -A XRAY_TRAFFIC -p tcp --dport $port
            # Исходящий трафик
            iptables -A XRAY_TRAFFIC -p tcp --sport $port
        done
        
        # Подключаем цепь к INPUT и OUTPUT
        if ! iptables -C INPUT -j XRAY_TRAFFIC &>/dev/null; then
            iptables -I INPUT -j XRAY_TRAFFIC
        fi
        if ! iptables -C OUTPUT -j XRAY_TRAFFIC &>/dev/null; then
            iptables -I OUTPUT -j XRAY_TRAFFIC
        fi
        
        echo -e "${GREEN}✓ Счётчики инициализированы${NC}"
    else
        echo -e "${GREEN}✓ Счётчики уже существуют${NC}"
    fi
}

# Функция для получения трафика через iptables
get_traffic_iptables() {
    local port=$1
    local direction=$2  # "in" или "out"
    
    if [ "$direction" = "in" ]; then
        iptables -L XRAY_TRAFFIC -n -v -x 2>/dev/null | grep "dpt:$port" | awk '{print $2}'
    else
        iptables -L XRAY_TRAFFIC -n -v -x 2>/dev/null | grep "spt:$port" | awk '{print $2}'
    fi
}

# Функция для сброса счётчиков
reset_counters() {
    echo -e "${YELLOW}Сбрасываем счётчики трафика...${NC}"
    iptables -Z XRAY_TRAFFIC 2>/dev/null
    echo -e "${GREEN}✓ Счётчики сброшены${NC}"
}

# Функция для удаления счётчиков
remove_counters() {
    echo -e "${YELLOW}Удаляем счётчики трафика...${NC}"
    
    # Удаляем правила из INPUT и OUTPUT
    iptables -D INPUT -j XRAY_TRAFFIC 2>/dev/null
    iptables -D OUTPUT -j XRAY_TRAFFIC 2>/dev/null
    
    # Очищаем и удаляем цепь
    iptables -F XRAY_TRAFFIC 2>/dev/null
    iptables -X XRAY_TRAFFIC 2>/dev/null
    
    echo -e "${GREEN}✓ Счётчики удалены${NC}"
}

# Функция для отображения текущего трафика
show_traffic() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║         📊 МОНИТОРИНГ ТРАФИКА XRAY (iptables)            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    # Проверяем наличие конфига
    if [ ! -f /usr/local/etc/xray/config.json ]; then
        echo -e "${RED}Ошибка: файл конфигурации Xray не найден${NC}"
        return 1
    fi
    
    # Инициализируем счётчики если нужно
    init_traffic_counters
    
    # Получаем информацию о портах и пользователях
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    if [ ${#ports[@]} -eq 0 ]; then
        echo -e "${RED}Ошибка: не найдены порты в конфигурации${NC}"
        return 1
    fi
    
    # Заголовок таблицы
    printf "${BLUE}%-15s${NC} ${GREEN}%-10s${NC} ${YELLOW}%-15s${NC} ${YELLOW}%-15s${NC} ${CYAN}%-15s${NC}\n" \
        "Пользователь" "Порт" "Входящий ↓" "Исходящий ↑" "Всего"
    echo "────────────────────────────────────────────────────────────────────────"
    
    local total_in=0
    local total_out=0
    
    # Выводим информацию по каждому порту
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        
        # Получаем трафик через iptables
        local bytes_in=$(get_traffic_iptables "$port" "in")
        local bytes_out=$(get_traffic_iptables "$port" "out")
        
        # Если данных нет, ставим 0
        bytes_in=${bytes_in:-0}
        bytes_out=${bytes_out:-0}
        
        # Считаем общий трафик
        local total=$(echo "$bytes_in + $bytes_out" | bc 2>/dev/null || echo "0")
        
        # Накапливаем итоги
        total_in=$(echo "$total_in + $bytes_in" | bc 2>/dev/null || echo "0")
        total_out=$(echo "$total_out + $bytes_out" | bc 2>/dev/null || echo "0")
        
        # Форматируем и выводим
        local formatted_in=$(format_bytes "$bytes_in")
        local formatted_out=$(format_bytes "$bytes_out")
        local formatted_total=$(format_bytes "$total")
        
        # Цветной индикатор активности
        if [ "$total" != "0" ]; then
            printf "${GREEN}%-15s${NC} %-10s %-15s %-15s ${CYAN}%-15s${NC}\n" \
                "$tag" "$port" "$formatted_in" "$formatted_out" "$formatted_total"
        else
            printf "%-15s %-10s %-15s %-15s %-15s\n" \
                "$tag" "$port" "$formatted_in" "$formatted_out" "$formatted_total"
        fi
    done
    
    # Итоговая строка
    echo "────────────────────────────────────────────────────────────────────────"
    local grand_total=$(echo "$total_in + $total_out" | bc 2>/dev/null || echo "0")
    printf "${YELLOW}%-15s${NC} %-10s ${YELLOW}%-15s${NC} ${YELLOW}%-15s${NC} ${GREEN}%-15s${NC}\n" \
        "ИТОГО:" "-" "$(format_bytes $total_in)" "$(format_bytes $total_out)" "$(format_bytes $grand_total)"
    echo ""
}

# Функция для отображения активных соединений
show_connections() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              🔗 АКТИВНЫЕ СОЕДИНЕНИЯ                       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json 2>/dev/null))
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json 2>/dev/null))
    
    for i in "${!ports[@]}"; do
        local port="${ports[$i]}"
        local tag="${tags[$i]}"
        local connections=$(ss -tn | grep ":$port " | grep ESTAB | wc -l)
        
        if [ "$connections" -gt 0 ]; then
            echo -e "${GREEN}$tag${NC} (порт $port): ${YELLOW}$connections${NC} активных соединений"
            ss -tn | grep ":$port " | grep ESTAB | awk '{print "  └─ " $5}' | head -5
            if [ "$connections" -gt 5 ]; then
                echo "  └─ ... и ещё $(($connections - 5)) соединений"
            fi
            echo ""
        fi
    done
}

# Функция для непрерывного мониторинга
watch_traffic() {
    local interval=${1:-3}
    
    echo -e "${YELLOW}Непрерывный мониторинг (обновление каждые ${interval}с, Ctrl+C для выхода)${NC}"
    echo ""
    
    while true; do
        clear
        show_traffic
        show_connections
        echo ""
        echo -e "${BLUE}Следующее обновление через ${interval}с...${NC}"
        sleep $interval
    done
}

# Функция для экспорта данных в CSV
export_csv() {
    local filename="${1:-traffic_$(date +%Y%m%d_%H%M%S).csv}"
    
    echo "Timestamp,User,Port,Incoming_Bytes,Outgoing_Bytes,Total_Bytes" > "$filename"
    
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
        
        echo "$timestamp,$tag,$port,$bytes_in,$bytes_out,$total" >> "$filename"
    done
    
    echo -e "${GREEN}✓ Данные экспортированы в $filename${NC}"
}

# Главное меню
show_menu() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           📊 МОНИТОРИНГ ТРАФИКА XRAY                      ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "1) Показать текущий трафик"
    echo "2) Показать активные соединения"
    echo "3) Непрерывный мониторинг (watch)"
    echo "4) Сбросить счётчики"
    echo "5) Экспорт в CSV"
    echo "6) Инициализировать счётчики"
    echo "7) Удалить счётчики"
    echo "0) Выход"
    echo ""
    read -p "Выберите действие: " choice
    
    case $choice in
        1) show_traffic ;;
        2) show_connections ;;
        3) 
            read -p "Интервал обновления (сек, по умолчанию 3): " interval
            interval=${interval:-3}
            watch_traffic $interval
            ;;
        4) reset_counters ;;
        5) 
            read -p "Имя файла (Enter для автоматического): " filename
            export_csv "$filename"
            ;;
        6) init_traffic_counters ;;
        7) 
            read -p "Вы уверены? (y/n): " confirm
            if [ "$confirm" = "y" ]; then
                remove_counters
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}Неверный выбор${NC}" ;;
    esac
    
    if [ "$choice" != "3" ] && [ "$choice" != "0" ]; then
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

# Если запущен с аргументом, выполняем соответствующую команду
if [ $# -gt 0 ]; then
    case "$1" in
        show|traffic) show_traffic ;;
        connections|conn) show_connections ;;
        watch|monitor) watch_traffic ${2:-3} ;;
        reset) reset_counters ;;
        export) export_csv "$2" ;;
        init) init_traffic_counters ;;
        remove) remove_counters ;;
        *) 
            echo "Использование: $0 [show|connections|watch|reset|export|init|remove]"
            exit 1
            ;;
    esac
else
    # Интерактивное меню
    show_menu
fi
