#!/bin/bash

MAX_PARALLEL=5
COUNTER=0
LOG_DIR="./logs"
ACCOUNTS_FILE="accounts.txt"
TEMP_AUTH_OK="auth_ok.tmp"
TEMP_AUTH_FAIL="auth_fail.tmp"

mkdir -p "$LOG_DIR"
> "$TEMP_AUTH_OK"
> "$TEMP_AUTH_FAIL"

echo "🛠 Проверка Docker..."
if ! command -v docker &>/dev/null; then
    echo "Docker не найден. Устанавливаю..."
    apt update && apt install -y docker.io || { echo "❌ Не удалось установить Docker"; exit 1; }
fi

echo "🐳 Проверка образа imapsync..."
if ! docker image inspect gilleslamiral/imapsync &>/dev/null; then
    echo "Образ imapsync не найден. Загружаю..."
    docker pull gilleslamiral/imapsync
fi

echo "📂 Проверка наличия файла $ACCOUNTS_FILE..."
if [[ ! -f "$ACCOUNTS_FILE" ]]; then
    echo "Файл $ACCOUNTS_FILE не найден. Создаю пустой шаблон."
    echo '"src_email","src_imap","src_pass","dst_email","dst_pass","dst_imap"' > "$ACCOUNTS_FILE"
    exit 0
fi

echo "🔐 Проверка авторизации..."
while IFS=, read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP; do
    SRC_EMAIL=$(echo "$SRC_EMAIL" | tr -d '"')
    DST_EMAIL=$(echo "$DST_EMAIL" | tr -d '"')

    docker run --rm gilleslamiral/imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" \
        --justconnect --nosslcheck > /dev/null 2>&1

    if [[ $? -eq 0 ]]; then
        echo "✅ Авторизация успешна: $SRC_EMAIL"
        echo "$SRC_EMAIL" >> "$TEMP_AUTH_OK"
    else
        echo "❌ Ошибка авторизации: $SRC_EMAIL"
        echo "$SRC_EMAIL" >> "$TEMP_AUTH_FAIL"
    fi
done < <(tail -n +2 "$ACCOUNTS_FILE")

echo
echo "📋 Успешные: $(wc -l < "$TEMP_AUTH_OK")"
echo "🛑 Ошибки: $(wc -l < "$TEMP_AUTH_FAIL")"
if [[ -s "$TEMP_AUTH_FAIL" ]]; then
    echo "Вот список с ошибками:"
    cat "$TEMP_AUTH_FAIL"
fi

read -p "⏭ Продолжить перенос? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 0

START_TIME=$(date +%s)
echo "🕒 Начало: $(date)"

function migrate_mailbox() {
    local SRC_EMAIL=$1 SRC_IMAP=$2 SRC_PASS=$3
    local DST_EMAIL=$4 DST_PASS=$5 DST_IMAP=$6

    local LOG_FILE="$LOG_DIR/$(echo "$SRC_EMAIL" | tr '@' '_' | tr '.' '_').log"

    echo "🚀 Старт переноса: $SRC_EMAIL -> $DST_EMAIL"

    docker run --rm \
        -v "$(pwd)/$LOG_DIR:/tmp/logs" \
        gilleslamiral/imapsync \
        --host1 "$SRC_IMAP" --user1 "$SRC_EMAIL" --password1 "$SRC_PASS" \
        --host2 "$DST_IMAP" --user2 "$DST_EMAIL" --password2 "$DST_PASS" \
        --automap --skipcrossduplicates --useuid --nofoldersizes \
        --logfile "/tmp/logs/$(basename "$LOG_FILE")" \
        --log --debugcontent > /dev/null &
}

while IFS=, read -r SRC_EMAIL SRC_IMAP SRC_PASS DST_EMAIL DST_PASS DST_IMAP; do
    SRC_EMAIL=$(echo "$SRC_EMAIL" | tr -d '"')
    DST_EMAIL=$(echo "$DST_EMAIL" | tr -d '"')
    SRC_IMAP=$(echo "$SRC_IMAP" | tr -d '"')
    SRC_PASS=$(echo "$SRC_PASS" | tr -d '"')
    DST_IMAP=$(echo "$DST_IMAP" | tr -d '"')
    DST_PASS=$(echo "$DST_PASS" | tr -d '"')

    if grep -q "$SRC_EMAIL" "$TEMP_AUTH_OK"; then
        migrate_mailbox "$SRC_EMAIL" "$SRC_IMAP" "$SRC_PASS" "$DST_EMAIL" "$DST_PASS" "$DST_IMAP"
        ((COUNTER++))
        if (( COUNTER % MAX_PARALLEL == 0 )); then
            wait
        fi
    fi
done < <(tail -n +2 "$ACCOUNTS_FILE")

wait

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo "✅ Перенос завершён для всех ящиков. Время: $DURATION сек (~$((DURATION / 60)) мин)"
