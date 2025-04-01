#!/bin/bash

MAX_PARALLEL=5
COUNTER=0
AUTH_OK=()
AUTH_FAIL=()

ACCOUNTS_FILE="accounts.txt"
LOG_DIR="logs"
mkdir -p "$LOG_DIR"

echo "🕒 Начало проверки логинов: $(date)"

if ! command -v imapsync &> /dev/null; then
    echo "❌ imapsync не установлен!"
    exit 1
fi

# 🔍 Проверка логинов
while IFS=';' read -r SRC_EMAIL SRC_PASS SRC_IMAP DST_EMAIL DST_PASS DST_IMAP; do
    SRC_EMAIL=$(echo "$SRC_EMAIL" | tr -d '"')
    DST_EMAIL=$(echo "$DST_EMAIL" | tr -d '"')
    SRC_PASS=$(echo "$SRC_PASS" | tr -d '"')
    DST_PASS=$(echo "$DST_PASS" | tr -d '"')
    SRC_IMAP=$(echo "$SRC_IMAP" | tr -d '"')
    DST_IMAP=$(echo "$DST_IMAP" | tr -d '"')

    LOG_FILE="$LOG_DIR/imapcheck_$(echo $SRC_EMAIL | tr '@.' '__').log"

    echo "🔐 Проверка логина: $SRC_EMAIL -> $DST_EMAIL"

    imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" --ssl1 --port1 993 \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" --ssl2 --port2 993 \
        --authmech1 LOGIN --authmech2 LOGIN \
        --justlogin \
        > "$LOG_FILE" 2>&1

    if [ $? -eq 0 ]; then
        AUTH_OK+=("$SRC_EMAIL")
    else
        AUTH_FAIL+=("$SRC_EMAIL")
    fi

done < "$ACCOUNTS_FILE"

# 📋 Вывод результатов
echo -e "\n✅ Успешная авторизация:"
for email in "${AUTH_OK[@]}"; do
    echo "   ✔️ $email"
done

echo -e "\n❌ Ошибка авторизации:"
for email in "${AUTH_FAIL[@]}"; do
    echo "   ⛔ $email"
done

# ❓ Подтверждение
echo -e "\nПродолжить перенос только для успешно авторизованных аккаунтов? (y/n)"
read -r CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "⛔ Перенос отменён пользователем."
    exit 0
fi

# 💌 --- ПЕРЕНОС ПОЧТЫ --- 💌

declare -A PIDS
declare -A EMAILS
ERROR_LOGS=()

show_progress() {
    local LOG_FILE="$1"
    local EMAIL="$2"

    while kill -0 "${PIDS[$EMAIL]}" 2>/dev/null; do
        SIZE_MB=$(grep -Eo '[0-9]+ msg in [0-9]+\.[0-9]+ MiB' "$LOG_FILE" | tail -n1 | awk '{print $5}')
        echo "📡 [$EMAIL] Перенесено: ${SIZE_MB:-0.0} MiB"
        sleep 5
    done
}

for SRC_EMAIL in "${AUTH_OK[@]}"; do
    # Получаем данные из accounts.txt для этого ящика
    LINE=$(grep "$SRC_EMAIL" "$ACCOUNTS_FILE")
    IFS=';' read -r SRC_EMAIL SRC_PASS SRC_IMAP DST_EMAIL DST_PASS DST_IMAP <<< "$LINE"

    SRC_EMAIL=$(echo "$SRC_EMAIL" | tr -d '"')
    DST_EMAIL=$(echo "$DST_EMAIL" | tr -d '"')
    SRC_PASS=$(echo "$SRC_PASS" | tr -d '"')
    DST_PASS=$(echo "$DST_PASS" | tr -d '"')
    SRC_IMAP=$(echo "$SRC_IMAP" | tr -d '"')
    DST_IMAP=$(echo "$DST_IMAP" | tr -d '"')

    LOG_FILE="${LOG_DIR}/$(echo $SRC_EMAIL | tr '@.' '__').log"

    echo "🚀 Старт переноса: $SRC_EMAIL -> $DST_EMAIL"

    (
        imapsync \
            --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" --ssl1 --port1 993 \
            --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" --ssl2 --port2 993 \
            --authmech1 LOGIN --authmech2 LOGIN \
            --automap --skipcrossduplicates --useuid \
            --nofoldersizes --nolog \
            > "$LOG_FILE" 2>&1

        if grep -q "AUTHENTICATIONFAILED" "$LOG_FILE"; then
            ERROR_LOGS+=("$SRC_EMAIL")
        fi
    ) &

    PID=$!
    PIDS["$SRC_EMAIL"]=$PID
    EMAILS["$SRC_EMAIL"]=$LOG_FILE

    show_progress "$LOG_FILE" "$SRC_EMAIL" &

    ((COUNTER++))
    if (( COUNTER % MAX_PARALLEL == 0 )); then
        wait
    fi
done

wait

# 🧾 Итог
echo -e "\n✅ Перенос завершен: $(date)"

if [ ${#ERROR_LOGS[@]} -gt 0 ]; then
    echo -e "\n🚫 Ошибки авторизации во время переноса:"
    for EMAIL in "${ERROR_LOGS[@]}"; do
        echo "   ⛔ $EMAIL"
    done
else
    echo -e "\n🎉 Перенос выполнен без ошибок авторизации!"
fi
