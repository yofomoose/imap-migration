#!/bin/bash

MAX_PARALLEL=5
ACCOUNTS_FILE="accounts.txt"
LOGS_DIR="logs"
AUTH_LOG="auth_check.log"
START_TIME=$(date +%s)

mkdir -p "$LOGS_DIR"
> "$AUTH_LOG"

echo "🔍 Начало проверки авторизации: $(date)"

# Авторизация через expect
authorize_account() {
    local login="$1"
    local pass="$2"
    local server="$3"

    expect <<EOF >> "$AUTH_LOG"
        set timeout 5
        spawn openssl s_client -crlf -quiet -connect $server:993
        expect {
            "*OK*" {
                send "a login $login \"$pass\"\r"
                expect {
                    "*OK*" {
                        puts "✅ $login - $server: Авторизация успешна"
                        exit 0
                    }
                    "*NO*" {
                        puts "❌ $login - $server: Ошибка авторизации"
                        exit 1
                    }
                    timeout {
                        puts "❌ $login - $server: Таймаут при авторизации"
                        exit 2
                    }
                }
            }
            timeout {
                puts "❌ $login - $server: Сервер не отвечает"
                exit 3
            }
        }
EOF
    return $?
}

# Считывание и авторизация
declare -a AUTHORIZED_ACCOUNTS
while IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP; do
    SRC_PASS=$(echo "$SRC_PASS" | sed 's/^"//;s/"$//')
    DST_PASS=$(echo "$DST_PASS" | sed 's/^"//;s/"$//')
    SRC_EMAIL=$(echo "$SRC_EMAIL" | tr -d '\r\n')
    DST_EMAIL=$(echo "$DST_EMAIL" | tr -d '\r\n')

    authorize_account "$SRC_EMAIL" "$SRC_PASS" "$SRC_IMAP"
    AUTH1=$?
    authorize_account "$DST_EMAIL" "$DST_PASS" "$DST_IMAP"
    AUTH2=$?

    if [[ $AUTH1 -eq 0 && $AUTH2 -eq 0 ]]; then
        AUTHORIZED_ACCOUNTS+=("$SRC_EMAIL,$SRC_PASS,$SRC_IMAP,$DST_EMAIL,$DST_PASS,$DST_IMAP")
    fi
done < <(tail -n +1 "$ACCOUNTS_FILE")

echo
echo "📄 Результаты авторизации:"
cat "$AUTH_LOG"

if [ ${#AUTHORIZED_ACCOUNTS[@]} -eq 0 ]; then
    echo "❌ Нет успешно авторизованных ящиков. Завершение."
    exit 1
fi

read -p "🚀 Продолжить перенос для ${#AUTHORIZED_ACCOUNTS[@]} ящиков? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && echo "❌ Отменено пользователем." && exit 0

echo "🚀 Начало переноса: $(date)"

COUNTER=0
PIDS=()

for ACCOUNT in "${AUTHORIZED_ACCOUNTS[@]}"; do
    IFS=',' read -r SRC_EMAIL SRC_PASS SRC_IMAP DST_EMAIL DST_PASS DST_IMAP <<< "$ACCOUNT"

    LOG_FILE="${LOGS_DIR}/$(echo "$SRC_EMAIL" | tr '@.' '_').log"
    echo "🚀 Старт переноса: $SRC_EMAIL -> $DST_EMAIL"

    imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" \
        --automap --skipcrossduplicates --useuid \
        --nofoldersizes --ssl1 --ssl2 \
        > "$LOG_FILE" 2>&1 &

    PIDS+=($!)
    ((COUNTER++))

    if (( COUNTER % MAX_PARALLEL == 0 )); then
        wait "${PIDS[@]}"
        PIDS=()
    fi
done

wait "${PIDS[@]}"

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo
echo "✅ Перенос завершён. Общее время: $DURATION секунд (~$((DURATION / 60)) минут)"
echo "📂 Логи в папке: $LOGS_DIR"
