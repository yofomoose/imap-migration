#!/bin/bash

# Количество параллельных потоков
MAX_PARALLEL=5
LOG_DIR="logs"
CSV_FILE="accounts.txt"
AUTH_CHECK_LOG="auth_check.log"
TRANSFERRED_LOG="transferred.log"
DOCKER_IMAGE="gilleslamiral/imapsync"

mkdir -p "$LOG_DIR"
> "$AUTH_CHECK_LOG"
> "$TRANSFERRED_LOG"

echo "🔍 Начало проверки авторизации: $(date -u)"

# Проверка наличия Docker
if ! command -v docker &> /dev/null; then
    echo "Docker не установлен. Устанавливаю..."
    apt update && apt install -y docker.io
fi

# Проверка наличия образа imapsync
if ! docker image ls | grep -q "$DOCKER_IMAGE"; then
    echo "Образ imapsync не найден. Загружаю..."
    docker pull $DOCKER_IMAGE
fi

# Функция проверки авторизации
check_auth() {
    local email="$1"
    local server="$2"
    local pass="$3"

    expect -c "
        log_user 0
        spawn openssl s_client -crlf -connect $server:993
        expect \"OK\"
        send \"a login $email \\\"$pass\\\"\r\"
        expect {
            \"OK\" {
                puts \"✅ $email - $server: Авторизация успешна\" >> $AUTH_CHECK_LOG
                exit 0
            }
            \"NO\" {
                puts \"❌ $email - $server: Ошибка авторизации (неверный логин/пароль)\" >> $AUTH_CHECK_LOG
                exit 1
            }
            timeout {
                puts \"⏱ $email - $server: Таймаут подключения\" >> $AUTH_CHECK_LOG
                exit 2
            }
        }
    "
}

# Чтение CSV и проверка авторизации
mapfile -t valid_accounts < <(
    while IFS=, read -r src_email src_imap src_pass dst_email dst_pass dst_imap; do
        src_pass=${src_pass//\"/}
        dst_pass=${dst_pass//\"/}
        if check_auth "$src_email" "$src_imap" "$src_pass" && check_auth "$dst_email" "$dst_imap" "$dst_pass"; then
            echo "$src_email,$src_imap,$src_pass,$dst_email,$dst_pass,$dst_imap"
        fi
    done < <(tail -n +1 "$CSV_FILE" | sed 's/\r//' | sed 's/^"//;s/"$//' | sed 's/","/,/g')
)

echo
echo "📄 Результаты авторизации:"
cat "$AUTH_CHECK_LOG"

# Проверка наличия неавторизованных
if grep -q "❌" "$AUTH_CHECK_LOG" || grep -q "⏱" "$AUTH_CHECK_LOG"; then
    echo
    read -p "❗ Продолжить перенос для прошедших авторизацию? [y/N]: " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || exit 1
fi

echo "🚀 Начало переноса: $(date -u)"
START_TIME=$(date +%s)

COUNTER=0
PIDS=()

for line in "${valid_accounts[@]}"; do
    IFS=, read -r src_email src_imap src_pass dst_email dst_pass dst_imap <<< "$line"

    log_file="$LOG_DIR/$(echo "$src_email" | tr '@.' '_').log"
    echo "🚀 Старт переноса: $src_email -> $dst_email (PID будет создан)"

    docker run --rm \
        -v "$(pwd):/data" \
        --user "$(id -u):$(id -g)" \
        "$DOCKER_IMAGE" \
        imapsync \
        --host1 "$src_imap" --user1 "$src_email" --password1 "$src_pass" --ssl1 --port1 993 --authmech1 LOGIN \
        --host2 "$dst_imap" --user2 "$dst_email" --password2 "$dst_pass" --ssl2 --port2 993 --authmech2 LOGIN \
        --automap --skipcrossduplicates --useuid --nofoldersizes \
        --log /data/"$log_file" &
    
    pid=$!
    PIDS+=($pid)
    ((COUNTER++))

    if (( COUNTER % MAX_PARALLEL == 0 )); then
        wait "${PIDS[@]}"
        PIDS=()
    fi
done

# Ждем оставшиеся
wait "${PIDS[@]}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo
echo "✅ Перенос завершён. Общее время: $DURATION секунд (~$((DURATION / 60)) минут)"
echo "📂 Логи в папке: $LOG_DIR"
echo

# Вывод статистики
echo "📊 Объём переданных данных:"
grep "Transferred:" "$LOG_DIR"/*.log | awk -F ':' '{print $2}' | paste -sd+ - | bc | awk '{printf "%.2f MB\n", $1/1024}'
