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
> auth_check.log

while IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP; do
    # Убираем кавычки из полей
    SRC_EMAIL=$(echo "$SRC_EMAIL" | tr -d '"')
    SRC_IMAP=$(echo "$SRC_IMAP" | tr -d '"')
    SRC_PASS=$(echo "$SRC_PASS" | tr -d '"')
    DST_EMAIL=$(echo "$DST_EMAIL" | tr -d '"')
    DST_PASS=$(echo "$DST_PASS" | tr -d '"')
    DST_IMAP=$(echo "$DST_IMAP" | tr -d '"')

    for SERVER in "$SRC_IMAP" "$DST_IMAP"; do
        USER=$( [ "$SERVER" = "$SRC_IMAP" ] && echo "$SRC_EMAIL" || echo "$DST_EMAIL" )
        PASS=$( [ "$SERVER" = "$SRC_IMAP" ] && echo "$SRC_PASS" || echo "$DST_PASS" )

        expect -c "
            log_user 0
            spawn openssl s_client -crlf -connect $SERVER:993
            expect \"*OK*\"
            send \"a login $USER \\\"$PASS\\\"\r\"
            expect {
                \"OK\" {
                    puts \"✅ $USER - $SERVER: Авторизация успешна\"
                    puts \"✅ $USER - $SERVER: Авторизация успешна\" >> auth_check.log
                }
                \"NO\" {
                    puts \"❌ $USER - $SERVER: Неверный логин или пароль\"
                    puts \"❌ $USER - $SERVER: Неверный логин или пароль\" >> auth_check.log
                }
                timeout {
                    puts \"❌ $USER - $SERVER: Таймаут подключения\"
                    puts \"❌ $USER - $SERVER: Таймаут подключения\" >> auth_check.log
                }
            }
        "
    done
done < <(tail -n +2 accounts.txt)

echo
echo "📄 Результаты авторизации:"
cat auth_check.log
echo

read -rp "⏳ Продолжить перенос почты для успешно авторизованных ящиков? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "🚫 Перенос отменён."
    exit 1
fi

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
