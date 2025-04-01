#!/bin/bash

# Максимальное количество параллельных процессов
MAX_PARALLEL=5
COUNTER=0

ACCOUNTS_FILE="accounts.txt"
LOG_DIR="logs"
AUTH_LOG="auth_check.log"
TRANSFER_LOG="transfer_progress.log"
ERROR_LOG="errors.log"

mkdir -p "$LOG_DIR"
> "$AUTH_LOG"
> "$TRANSFER_LOG"
> "$ERROR_LOG"

echo "🔍 Начало проверки авторизации: $(date)"

# Функция проверки авторизации
check_auth() {
    local EMAIL="$1"
    local HOST="$2"
    local PASS="$3"

    expect <<EOF >> "$AUTH_LOG"
        log_user 0
        spawn openssl s_client -connect ${HOST}:993 -quiet
        expect "*OK*" {
            send "a login ${EMAIL} \"${PASS}\"\r"
        }
        expect {
            "*OK*" {
                puts "✅ ${EMAIL} - ${HOST}: Авторизация успешна"
            }
            "*NO*" {
                puts "❌ ${EMAIL} - ${HOST}: Ошибка авторизации (неверный логин/пароль)"
            }
            timeout {
                puts "❌ ${EMAIL} - ${HOST}: Таймаут при попытке подключения"
            }
            eof {
                puts "❌ ${EMAIL} - ${HOST}: Соединение закрыто"
            }
        }
        catch wait result
        exit 0
EOF
}

# Чтение и проверка аккаунтов
mapfile -t ACCOUNTS < <(tail -n +2 "$ACCOUNTS_FILE")

for LINE in "${ACCOUNTS[@]}"; do
    IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP <<< "$LINE"
    # Убираем кавычки у пароля, если есть
    SRC_PASS=$(echo "$SRC_PASS" | sed 's/^"\(.*\)"$/\1/')
    DST_PASS=$(echo "$DST_PASS" | sed 's/^"\(.*\)"$/\1/')
    check_auth "$SRC_EMAIL" "$SRC_IMAP" "$SRC_PASS" &
    check_auth "$DST_EMAIL" "$DST_IMAP" "$DST_PASS" &
done

wait
echo "📄 Результаты авторизации:"
cat "$AUTH_LOG"

if grep -q "❌" "$AUTH_LOG"; then
    echo "⚠ Обнаружены ошибки авторизации!"
fi

# Подтверждение продолжения
read -rp "Продолжить перенос почты? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "⛔ Перенос отменён пользователем." && exit 0

echo "🚀 Начало переноса: $(date)"

# Функция переноса почты
start_transfer() {
    local SRC_EMAIL="$1"
    local SRC_IMAP="$2"
    local SRC_PASS="$3"
    local DST_EMAIL="$4"
    local DST_PASS="$5"
    local DST_IMAP="$6"
    local LOG_FILE="$LOG_DIR/$(echo $SRC_EMAIL | tr '@.' '__').log"

    echo "🚀 Старт переноса: $SRC_EMAIL -> $DST_EMAIL"

    imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" --ssl1 \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" --ssl2 \
        --automap --skipcrossduplicates --useuid --nofoldersizes \
        --logfile "$LOG_FILE" \
        > "$LOG_FILE" 2>&1 &

    echo "$!" >> "$LOG_DIR/pids"
}

> "$LOG_DIR/pids"

for LINE in "${ACCOUNTS[@]}"; do
    IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP <<< "$LINE"
    SRC_PASS=$(echo "$SRC_PASS" | sed 's/^"\(.*\)"$/\1/')
    DST_PASS=$(echo "$DST_PASS" | sed 's/^"\(.*\)"$/\1/')

    start_transfer "$SRC_EMAIL" "$SRC_IMAP" "$SRC_PASS" "$DST_EMAIL" "$DST_PASS" "$DST_IMAP"

    ((COUNTER++))
    if (( COUNTER % MAX_PARALLEL == 0 )); then
        wait
    fi
done

wait

echo "✅ Перенос завершён. Общее время: $(date)"
echo "📂 Логи в папке: $LOG_DIR"
