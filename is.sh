#!/bin/bash

ACCOUNTS_FILE="accounts.csv"
LOGS_DIR="logs"
AUTH_LOG="auth_check.log"
MAX_PARALLEL=5
COUNTER=0

mkdir -p "$LOGS_DIR"
> "$AUTH_LOG"

echo "🔍 Начало проверки авторизации: $(date)"

check_auth() {
    local email="$1"
    local server="$2"
    local password="$3"

    expect <<EOF >> "$AUTH_LOG"
        log_user 0
        spawn openssl s_client -connect $server:993 -quiet
        expect {
            "*OK*" {
                send "a login $email \"$password\"\r"
                expect {
                    "*OK*" {
                        puts "✅ $email - $server: Авторизация успешна"
                        exit 0
                    }
                    "*NO*" {
                        puts "❌ $email - $server: Ошибка авторизации (неверный логин/пароль)"
                        exit 1
                    }
                    timeout {
                        puts "❌ $email - $server: Таймаут при авторизации"
                        exit 1
                    }
                }
            }
            timeout {
                puts "❌ $email - $server: Нет ответа от сервера"
                exit 1
            }
        }
EOF
}

mapfile -t AUTH_LINES < <(tail -n +2 "$ACCOUNTS_FILE")
GOOD_ACCOUNTS=()
BAD_ACCOUNTS=()

for line in "${AUTH_LINES[@]}"; do
    IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP <<<"$(echo "$line" | sed 's/^"\(.*\)"$/\1/' | awk -F'","?' '{ for(i=1;i<=NF;i++) gsub(/^"|"$/, "", $i); print }')"

    check_auth "$SRC_EMAIL" "$SRC_IMAP" "$SRC_PASS" && \
    check_auth "$DST_EMAIL" "$DST_IMAP" "$DST_PASS"

    if [[ $? -eq 0 ]]; then
        GOOD_ACCOUNTS+=("$line")
    else
        BAD_ACCOUNTS+=("$line")
    fi
done

echo -e "\n📄 Результаты авторизации:"
cat "$AUTH_LOG"

if [ "${#GOOD_ACCOUNTS[@]}" -eq 0 ]; then
    echo "❌ Нет успешно авторизованных ящиков. Завершение."
    exit 1
fi

echo
read -rp "🔄 Продолжить перенос для ${#GOOD_ACCOUNTS[@]} ящиков? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

echo -e "\n🚀 Начало переноса: $(date)"
START_TIME=$(date +%s)

for line in "${GOOD_ACCOUNTS[@]}"; do
    IFS=',' read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP <<<"$(echo "$line" | sed 's/^"\(.*\)"$/\1/' | awk -F'","?' '{ for(i=1;i<=NF;i++) gsub(/^"|"$/, "", $i); print }')"

    LOG_FILE="$LOGS_DIR/$(echo "$SRC_EMAIL" | tr '@' '_' | tr '.' '_').log"
    echo "🚀 Старт переноса: $SRC_EMAIL -> $DST_EMAIL (PID будет создан)"

    imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" --ssl1 \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" --ssl2 \
        --automap --useuid --nofoldersizes \
        --log "$LOG_FILE" \
        --progress \
        &

    ((COUNTER++))
    if (( COUNTER % MAX_PARALLEL == 0 )); then
        wait
    fi
done

wait

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo -e "\n✅ Перенос завершён. Общее время: $DURATION секунд (~$((DURATION / 60)) минут)"
echo "📂 Логи в папке: $LOGS_DIR"
