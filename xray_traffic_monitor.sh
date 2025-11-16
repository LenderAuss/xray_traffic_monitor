#!/bin/bash

# Скрипт автоматического контроля времени Xray
# Мониторит пользователей и автоматически удаляет при истечении времени (для пользователей без подписки)

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Конфигурация по умолчанию
DEFAULT_TIME_LIMIT_HOURS=24
DEFAULT_CHECK_INTERVAL=60
LOG_FILE="/var/log/xray_time_control.log"

# Функция логирования
log_message() {
    local message="$1"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Функция для вычисления времени жизни пользователя в часах
get_user_age_hours() {
    local created_date="$1"
    
    # Преобразуем дату создания в timestamp
    local created_timestamp=$(date -d "$created_date" +%s 2>/dev/null)
    
    if [ -z "$created_timestamp" ] || [ "$created_timestamp" = "" ]; then
        echo "0"
        return 1
    fi
    
    # Текущий timestamp
    local current_timestamp=$(date +%s)
    
    # Разница в секундах
    local diff_seconds=$((current_timestamp - created_timestamp))
    
    # Конвертируем в часы
    local hours=$(echo "scale=2; $diff_seconds / 3600" | bc)
    
    echo "$hours"
}

# Функция для получения номера пользователя по тегу
get_user_number_by_tag() {
    local target_tag="$1"
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    
    for i in "${!tags[@]}"; do
        if [ "${tags[$i]}" = "$target_tag" ]; then
            echo $((i + 1))
            return 0
        fi
    done
    
    echo "0"
    return 1
}

# Функция для удаления пользователя
remove_user() {
    local user_number=$1
    local user_tag=$2
    local age_hours=$3
    local time_limit=$4
    
    echo -e "${YELLOW}⚠️  Пользователь '$user_tag' (№$user_number): Истёк срок действия${NC}"
    echo -e "    Прошло: ${age_hours}h / Лимит: ${time_limit}h"
    log_message "WARNING: User '$user_tag' (#$user_number) - Time expired: ${age_hours}h / ${time_limit}h"
    
    # Автоматически удаляем пользователя
    echo -e "${RED}🗑️  Удаление пользователя '$user_tag'...${NC}"
    log_message "ACTION: Removing user '$user_tag' (#$user_number)"
    
    # Используем rmuser с автоматическим вводом номера
    echo "$user_number" | rmuser &>/dev/null
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Пользователь '$user_tag' успешно удалён${NC}"
        log_message "SUCCESS: User '$user_tag' removed successfully - Time expired"
        
        # Отправить уведомление (если настроено)
        send_notification "🗑️ Удалён пользователь: $user_tag" "Причина: истёк срок действия\nПрошло: ${age_hours}h / Лимит: ${time_limit}h"
        
        return 0
    else
        echo -e "${RED}❌ Ошибка при удалении пользователя '$user_tag'${NC}"
        log_message "ERROR: Failed to remove user '$user_tag'"
        return 1
    fi
}

# Функция для отправки уведомлений (опционально)
send_notification() {
    local title="$1"
    local message="$2"
    
    # Telegram уведомление (если настроено)
    if [ -f /etc/xray/telegram.conf ]; then
        source /etc/xray/telegram.conf
        if [ -n "$BOT_TOKEN" ] && [ -n "$CHAT_ID" ]; then
            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d chat_id="${CHAT_ID}" \
                -d text="$title\n$message" \
                &>/dev/null
        fi
    fi
}

# Функция мониторинга
monitor_users() {
    local time_limit_hours=$1
    local check_interval=$2
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           🔍 АВТОМАТИЧЕСКИЙ КОНТРОЛЬ ВРЕМЕНИ XRAY              ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}⚙️  Настройки:${NC}"
    echo -e "   Лимит времени (без подписки): ${GREEN}${time_limit_hours} часов${NC}"
    echo -e "   Интервал проверки: ${GREEN}${check_interval} секунд${NC}"
    echo -e "   Лог файл: ${BLUE}${LOG_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}📝 Запуск мониторинга... (Ctrl+C для остановки)${NC}"
    echo ""
    
    log_message "=== Monitoring started. Time limit: ${time_limit_hours}h, Interval: ${check_interval}s ==="
    
    local check_count=0
    
    while true; do
        check_count=$((check_count + 1))
        
        local current_time=$(date '+%Y-%m-%d %H:%M:%S')
        echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}🔍 Проверка #${check_count} - ${current_time}${NC}"
        echo ""
        
        # Получаем список пользователей
        local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
        local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
        
        if [ ${#tags[@]} -eq 0 ]; then
            echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
            log_message "INFO: No active users found"
        else
            local users_checked=0
            local users_removed=0
            
            # Проверяем каждого пользователя
            for i in "${!tags[@]}"; do
                local tag="${tags[$i]}"
                local port="${ports[$i]}"
                local user_number=$((i + 1))
                
                # Получаем метаданные пользователя
                local subscription=$(jq -r ".inbounds[$i].metadata.subscription // \"n/a\"" /usr/local/etc/xray/config.json)
                local created_date=$(jq -r ".inbounds[$i].metadata.created_date // \"n/a\"" /usr/local/etc/xray/config.json)
                
                # Получаем возраст пользователя в часах
                local age_hours="0"
                if [ "$created_date" != "n/a" ]; then
                    age_hours=$(get_user_age_hours "$created_date")
                fi
                
                local should_remove=false
                
                # Проверка: Истечение времени для пользователей без подписки
                if [ "$subscription" = "n" ] && [ "$created_date" != "n/a" ]; then
                    if (( $(echo "$age_hours >= $time_limit_hours" | bc -l) )); then
                        should_remove=true
                    fi
                fi
                
                # Удаляем пользователя если нужно
                if [ "$should_remove" = true ]; then
                    users_removed=$((users_removed + 1))
                    echo -e "${RED}❌ [$user_number] $tag (порт $port)${NC}"
                    echo -e "   Подписка: $subscription | Создан: $created_date"
                    echo -e "   Возраст: ${age_hours}h / Лимит: ${time_limit_hours}h"
                    
                    remove_user "$user_number" "$tag" "$age_hours" "$time_limit_hours"
                    
                    # После удаления обновляем списки
                    tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
                    ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
                    
                    echo ""
                else
                    # Пользователь в норме
                    local time_status=""
                    
                    if [ "$subscription" = "n" ] && [ "$created_date" != "n/a" ]; then
                        local time_percent=$(echo "scale=1; $age_hours * 100 / $time_limit_hours" | bc)
                        local remaining=$(echo "scale=2; $time_limit_hours - $age_hours" | bc)
                        time_status="Возраст: ${age_hours}h / ${time_limit_hours}h (${time_percent}%) | Осталось: ${remaining}h"
                    elif [ "$subscription" = "y" ]; then
                        time_status="Подписка: активна (∞)"
                    else
                        time_status="Подписка: n/a | Дата создания: отсутствует"
                    fi
                    
                    echo -e "${GREEN}✓${NC} [$user_number] $tag (порт $port)"
                    echo -e "   $time_status"
                fi
                
                users_checked=$((users_checked + 1))
            done
            
            echo ""
            echo -e "${CYAN}📊 Статистика проверки:${NC}"
            echo -e "   Проверено пользователей: ${users_checked}"
            if [ $users_removed -gt 0 ]; then
                echo -e "   Удалено: ${RED}${users_removed}${NC}"
            else
                echo -e "   Удалено: ${GREEN}0${NC}"
            fi
        fi
        
        echo ""
        echo -e "${BLUE}⏳ Следующая проверка через ${check_interval} секунд...${NC}"
        echo ""
        
        sleep "$check_interval"
    done
}

# Функция одноразовой проверки
check_once() {
    local time_limit_hours=$1
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║          🔍 ПРОВЕРКА ВРЕМЕНИ ПОЛЬЗОВАТЕЛЕЙ (ОДНОРАЗОВО)       ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Лимит времени (без подписки): ${time_limit_hours} часов${NC}"
    echo ""
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        return 0
    fi
    
    printf "${BLUE}%-5s${NC} ${GREEN}%-15s${NC} ${YELLOW}%-8s${NC} ${CYAN}%-12s${NC} ${MAGENTA}%-15s${NC} ${WHITE}%-10s${NC}\n" \
        "#" "Пользователь" "Порт" "Подписка" "Возраст" "Статус"
    echo "────────────────────────────────────────────────────────────────────────────────"
    
    local total_to_remove=0
    local users_to_remove=()
    
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port="${ports[$i]}"
        local user_number=$((i + 1))
        
        # Получаем метаданные
        local subscription=$(jq -r ".inbounds[$i].metadata.subscription // \"n/a\"" /usr/local/etc/xray/config.json)
        local created_date=$(jq -r ".inbounds[$i].metadata.created_date // \"n/a\"" /usr/local/etc/xray/config.json)
        
        # Получаем возраст
        local age_hours="0"
        if [ "$created_date" != "n/a" ]; then
            age_hours=$(get_user_age_hours "$created_date")
        fi
        
        local should_remove=false
        local status="OK"
        
        # Проверяем условия
        if [ "$subscription" = "n" ] && [ "$created_date" != "n/a" ]; then
            if (( $(echo "$age_hours >= $time_limit_hours" | bc -l) )); then
                should_remove=true
                status="${RED}ИСТЁК${NC}"
            else
                local time_percent=$(echo "scale=0; $age_hours * 100 / $time_limit_hours" | bc)
                status="${GREEN}OK (${time_percent}%)${NC}"
            fi
        elif [ "$subscription" = "y" ]; then
            status="${GREEN}∞${NC}"
        else
            status="${YELLOW}N/A${NC}"
        fi
        
        # Форматируем вывод
        if [ "$should_remove" = true ]; then
            printf "%-5s %-15s %-8s %-12s ${RED}%-15s${NC} %b\n" \
                "$user_number" "$tag" "$port" "$subscription" "${age_hours}h" "$status"
            total_to_remove=$((total_to_remove + 1))
            users_to_remove+=("$user_number|$tag|$age_hours")
        else
            local age_display="${age_hours}h"
            if [ "$subscription" = "y" ]; then
                age_display="${age_hours}h (∞)"
            fi
            printf "%-5s %-15s %-8s %-12s %-15s %b\n" \
                "$user_number" "$tag" "$port" "$subscription" "$age_display" "$status"
        fi
    done
    
    echo ""
    if [ $total_to_remove -gt 0 ]; then
        echo -e "${RED}⚠️  Пользователей для удаления: ${total_to_remove}${NC}"
        echo ""
        
        read -p "Удалить пользователей с истёкшим сроком? (y/n): " confirm
        if [ "$confirm" = "y" ] || [ "$confirm" = "Y" ]; then
            # Удаляем в обратном порядке, чтобы не сбивались номера
            for ((idx=${#users_to_remove[@]}-1; idx>=0; idx--)); do
                IFS='|' read -r user_num user_tag user_age <<< "${users_to_remove[$idx]}"
                remove_user "$user_num" "$user_tag" "$user_age" "$time_limit_hours"
                
                # Обновляем списки после каждого удаления
                tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
                ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
                
                # Пересчитываем номера оставшихся пользователей
                declare -a new_users_to_remove=()
                for item in "${users_to_remove[@]}"; do
                    IFS='|' read -r num tag age <<< "$item"
                    if [ "$num" != "$user_num" ]; then
                        if [ "$num" -gt "$user_num" ]; then
                            num=$((num - 1))
                        fi
                        new_users_to_remove+=("$num|$tag|$age")
                    fi
                done
                users_to_remove=("${new_users_to_remove[@]}")
            done
        fi
    else
        echo -e "${GREEN}✅ Все пользователи в пределах лимита времени${NC}"
    fi
}

# Функция просмотра статуса всех пользователей
show_status() {
    local time_limit_hours=$1
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                 📊 СТАТУС ВСЕХ ПОЛЬЗОВАТЕЛЕЙ                  ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Лимит времени (без подписки): ${time_limit_hours} часов${NC}"
    echo ""
    
    local tags=($(jq -r '.inbounds[].tag' /usr/local/etc/xray/config.json))
    local ports=($(jq -r '.inbounds[].port' /usr/local/etc/xray/config.json))
    
    if [ ${#tags[@]} -eq 0 ]; then
        echo -e "${YELLOW}⚠️  Нет активных пользователей${NC}"
        return 0
    fi
    
    echo "════════════════════════════════════════════════════════════════════════════════"
    
    for i in "${!tags[@]}"; do
        local tag="${tags[$i]}"
        local port="${ports[$i]}"
        local user_number=$((i + 1))
        
        # Получаем метаданные
        local subscription=$(jq -r ".inbounds[$i].metadata.subscription // \"n/a\"" /usr/local/etc/xray/config.json)
        local created_date=$(jq -r ".inbounds[$i].metadata.created_date // \"n/a\"" /usr/local/etc/xray/config.json)
        
        # Получаем возраст
        local age_hours="0"
        if [ "$created_date" != "n/a" ]; then
            age_hours=$(get_user_age_hours "$created_date")
        fi
        
        echo -e "${CYAN}[$user_number] $tag${NC}"
        echo "   Порт: $port"
        echo "   Подписка: $subscription"
        echo "   Создан: $created_date"
        
        if [ "$subscription" = "n" ] && [ "$created_date" != "n/a" ]; then
            local remaining=$(echo "scale=2; $time_limit_hours - $age_hours" | bc)
            local percent=$(echo "scale=1; $age_hours * 100 / $time_limit_hours" | bc)
            
            if (( $(echo "$age_hours >= $time_limit_hours" | bc -l) )); then
                echo -e "   Возраст: ${RED}${age_hours}h${NC} (${percent}%)"
                echo -e "   Статус: ${RED}ИСТЁК СРОК${NC}"
            else
                echo -e "   Возраст: ${GREEN}${age_hours}h${NC} из ${time_limit_hours}h (${percent}%)"
                echo -e "   Осталось: ${GREEN}${remaining}h${NC}"
                echo -e "   Статус: ${GREEN}АКТИВЕН${NC}"
            fi
        elif [ "$subscription" = "y" ]; then
            echo -e "   Возраст: ${age_hours}h"
            echo -e "   Статус: ${GREEN}АКТИВЕН (∞)${NC}"
        else
            echo -e "   Возраст: N/A"
            echo -e "   Статус: ${YELLOW}N/A${NC}"
        fi
        
        echo "────────────────────────────────────────────────────────────────────────────────"
    done
}

# Функция просмотра логов
show_logs() {
    local lines=${1:-20}
    
    if [ ! -f "$LOG_FILE" ]; then
        echo -e "${YELLOW}⚠️  Лог файл не найден${NC}"
        return 1
    fi
    
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    📜 ЛОГИ (последние ${lines})                    ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    tail -n "$lines" "$LOG_FILE" | while IFS= read -r line; do
        if [[ $line == *"ERROR"* ]]; then
            echo -e "${RED}$line${NC}"
        elif [[ $line == *"WARNING"* ]]; then
            echo -e "${YELLOW}$line${NC}"
        elif [[ $line == *"SUCCESS"* ]]; then
            echo -e "${GREEN}$line${NC}"
        else
            echo "$line"
        fi
    done
}

# Функция настройки Telegram уведомлений
setup_telegram() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║              📱 НАСТРОЙКА TELEGRAM УВЕДОМЛЕНИЙ                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    
    read -p "Введите BOT_TOKEN: " bot_token
    read -p "Введите CHAT_ID: " chat_id
    
    mkdir -p /etc/xray
    cat > /etc/xray/telegram.conf << EOF
BOT_TOKEN="$bot_token"
CHAT_ID="$chat_id"
EOF
    
    chmod 600 /etc/xray/telegram.conf
    
    echo -e "${GREEN}✅ Telegram уведомления настроены${NC}"
    echo ""
    
    # Тестовое уведомление
    read -p "Отправить тестовое уведомление? (y/n): " test
    if [ "$test" = "y" ]; then
        curl -s -X POST "https://api.telegram.org/bot${bot_token}/sendMessage" \
            -d chat_id="${chat_id}" \
            -d text="✅ Xray Time Control: Тестовое уведомление" \
            &>/dev/null
        echo -e "${GREEN}✅ Тестовое сообщение отправлено${NC}"
    fi
}

# Главное меню
show_menu() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║           🛡️  АВТОМАТИЧЕСКИЙ КОНТРОЛЬ ВРЕМЕНИ XRAY            ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo " 1) 🔄 Запустить мониторинг (непрерывный)"
    echo " 2) 🔍 Проверить сейчас (одноразово с удалением)"
    echo " 3) 📊 Показать статус всех пользователей"
    echo " 4) 📜 Показать логи"
    echo " 5) 📱 Настроить Telegram уведомления"
    echo " 6) ⚙️  Изменить настройки по умолчанию"
    echo " 0) ❌ Выход"
    echo ""
    read -p "Выберите действие: " choice
    
    case $choice in
        1)
            read -p "Лимит времени для пользователей без подписки в часах (по умолчанию $DEFAULT_TIME_LIMIT_HOURS): " time_limit
            time_limit=${time_limit:-$DEFAULT_TIME_LIMIT_HOURS}
            
            read -p "Интервал проверки в секундах (по умолчанию $DEFAULT_CHECK_INTERVAL): " interval
            interval=${interval:-$DEFAULT_CHECK_INTERVAL}
            
            monitor_users "$time_limit" "$interval"
            ;;
        2)
            read -p "Лимит времени для пользователей без подписки в часах (по умолчанию $DEFAULT_TIME_LIMIT_HOURS): " time_limit
            time_limit=${time_limit:-$DEFAULT_TIME_LIMIT_HOURS}
            
            check_once "$time_limit"
            ;;
        3)
            read -p "Лимит времени для справки в часах (по умолчанию $DEFAULT_TIME_LIMIT_HOURS): " time_limit
            time_limit=${time_limit:-$DEFAULT_TIME_LIMIT_HOURS}
            
            show_status "$time_limit"
            ;;
        4)
            read -p "Количество строк (по умолчанию 20): " lines
            lines=${lines:-20}
            show_logs "$lines"
            ;;
        5)
            setup_telegram
            ;;
        6)
            echo ""
            read -p "Лимит времени по умолчанию в часах ($DEFAULT_TIME_LIMIT_HOURS): " new_time_limit
            new_time_limit=${new_time_limit:-$DEFAULT_TIME_LIMIT_HOURS}
            
            read -p "Интервал проверки по умолчанию в секундах ($DEFAULT_CHECK_INTERVAL): " new_interval
            new_interval=${new_interval:-$DEFAULT_CHECK_INTERVAL}
            
            # Сохраняем в конфиг
            mkdir -p /etc/xray
            cat > /etc/xray/time_control.conf << EOF
DEFAULT_TIME_LIMIT_HOURS=$new_time_limit
DEFAULT_CHECK_INTERVAL=$new_interval
EOF
            
            echo -e "${GREEN}✅ Настройки сохранены${NC}"
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}Неверный выбор${NC}"
            ;;
    esac
    
    if [ "$choice" != "1" ] && [ "$choice" != "0" ]; then
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
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Ошибка: jq не установлен. Установите: apt install jq${NC}"
    exit 1
fi

if ! command -v bc &> /dev/null; then
    echo -e "${YELLOW}Установка bc...${NC}"
    apt-get update && apt-get install -y bc
fi

# Проверка наличия rmuser
if ! command -v rmuser &> /dev/null; then
    echo -e "${RED}Ошибка: команда rmuser не найдена${NC}"
    echo -e "${YELLOW}Убедитесь что установлен скрипт управления Xray${NC}"
    exit 1
fi

# Загрузить конфиг если есть
if [ -f /etc/xray/time_control.conf ]; then
    source /etc/xray/time_control.conf
fi

# Если запущен с аргументами
if [ $# -gt 0 ]; then
    case "$1" in
        monitor|watch|start)
            time_limit=${2:-$DEFAULT_TIME_LIMIT_HOURS}
            interval=${3:-$DEFAULT_CHECK_INTERVAL}
            monitor_users "$time_limit" "$interval"
            ;;
        check|once)
            time_limit=${2:-$DEFAULT_TIME_LIMIT_HOURS}
            check_once "$time_limit"
            ;;
        status)
            time_limit=${2:-$DEFAULT_TIME_LIMIT_HOURS}
            show_status "$time_limit"
            ;;
        logs)
            lines=${2:-20}
            show_logs "$lines"
            ;;
        telegram|setup-telegram)
            setup_telegram
            ;;
        *)
            echo "Использование: $0 [monitor|check|status|logs|telegram] [параметры]"
            echo ""
            echo "Примеры:"
            echo "  $0 monitor 24 60      - мониторинг: лимит 24ч, проверка каждые 60 сек"
            echo "  $0 monitor 0.5 30     - мониторинг: лимит 30 минут, проверка каждые 30 сек"
            echo "  $0 check 12           - проверить: лимит 12ч"
            echo "  $0 status 24          - показать статус с лимитом 24ч"
            echo "  $0 logs 50            - показать 50 последних строк лога"
            echo "  $0 telegram           - настроить Telegram"
            echo ""
            echo "Без аргументов запускается интерактивное меню"
            exit 1
            ;;
    esac
else
    # Интерактивное меню
    show_menu
fi
