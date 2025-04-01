#!/bin/bash

set -e

MAX_PARALLEL=5
COUNTER=0

ACCOUNTS_FILE="accounts.csv"
LOGS_DIR="logs"
AUTH_LOG="auth_check.log"

mkdir -p "$LOGS_DIR"
> "$AUTH_LOG"

START_TIME=$(date)

echo "🔍 Начало проверки авторизации: $START_TIME"

# Авторизация
while IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP; do
    SRC_PASS=$(echo "$SRC_PASS" | sed 's/^"//;s/"$//')
    DST_PASS=$(echo "$DST_PASS" | sed 's/^"//;s/"$//')

    for side in src dst; do
        if [ "$side" == "src" ]; then
            EMAIL="$SRC_EMAIL"
            IMAP="$SRC_IMAP"
            PASS="$SRC_PASS"
        else
            EMAIL="$DST_EMAIL"
            IMAP="$DST_IMAP"
            PASS="$DST_PASS"
        fi

        expect <<EOF > /dev/null 2>&1
        set timeout 10
        spawn openssl s_client -crlf -quiet -connect $IMAP:993
        expect "*OK*"
        send "a login $EMAIL \"$PASS\"
"
        expect {
            "OK" {
                puts "✅ $EMAIL - $IMAP: Авторизация успешна"
                puts "✅ $EMAIL - $IMAP: Авторизация успешна" >> "$AUTH_LOG"
            }
            "NO" {
                puts "❌ $EMAIL - $IMAP: Ошибка авторизации (неверный логин/пароль)"
                puts "❌ $EMAIL - $IMAP: Ошибка авторизации (неверный логин/пароль)" >> "$AUTH_LOG"
            }
            timeout {
                puts "❌ $EMAIL - $IMAP: Ошибка авторизации (таймаут)"
                puts "❌ $EMAIL - $IMAP: Ошибка авторизации (таймаут)" >> "$AUTH_LOG"
            }
        }
        EOF

    done
done < <(tail -n +1 "$ACCOUNTS_FILE")

echo ""
echo "📄 Результаты авторизации:"
cat "$AUTH_LOG"

# Запрос подтверждения
read -p "Продолжить перенос? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" ]]; then
    echo "⛔ Перенос отменён пользователем."
    exit 0
fi

echo "🚀 Начало переноса: $(date)"

# Запуск переноса
while IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP; do
    SRC_PASS=$(echo "$SRC_PASS" | sed 's/^"//;s/"$//')
    DST_PASS=$(echo "$DST_PASS" | sed 's/^"//;s/"$//')

    LOG_FILE="$LOGS_DIR/$(echo "$SRC_EMAIL" | tr '@' '_' | tr '.' '_').log"
    echo "🚀 Старт переноса: $SRC_EMAIL -> $DST_EMAIL"

    docker run --rm -v "$(pwd):/data" gilleslamiral/imapsync imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" --ssl1 \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" --ssl2 \
        --automap --skipcrossduplicates --useuid --nofoldersizes \
        --logfile "/data/$LOG_FILE" &

    ((COUNTER++))
    if (( COUNTER % MAX_PARALLEL == 0 )); then
        wait
    fi
done < <(tail -n +1 "$ACCOUNTS_FILE")

wait

END_TIME=$(date)
echo "✅ Перенос завершён. Время: $START_TIME — $END_TIME"
echo "📂 Логи в папке: $LOGS_DIR"
