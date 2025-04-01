#!/bin/bash

MAX_PARALLEL=4
ACCOUNTS_FILE="accounts.txt"
LOGS_DIR="logs"
AUTH_LOG="auth_failed.log"

mkdir -p "$LOGS_DIR"
> "$AUTH_LOG"

echo "🕒 Начало проверки авторизации: $(date)"
echo

check_auth() {
  local email="$1"
  local password="$2"
  local server="$3"

  response=$(expect -c "
    log_user 0
    spawn openssl s_client -crlf -connect $server:993
    expect \"* OK\"
    send \"a login $email \\\"$password\\\"\r\"
    expect {
      \"a OK\" {
        puts \"OK\"
        exit 0
      }
      \"a NO\" {
        puts \"NO: Ошибка авторизации (неверный логин/пароль)\"
        exit 1
      }
      \"a BAD\" {
        puts \"BAD: Неверный формат команды или ошибка на сервере\"
        exit 2
      }
      timeout {
        puts \"TIMEOUT: Сервер не ответил\"
        exit 3
      }
      eof {
        puts \"EOF: Сервер закрыл соединение\"
        exit 4
      }
    }
  ")

  status=$?
  if [[ $status -ne 0 ]]; then
    echo -e "❌ $email - $server - $response"
    echo "$email - $server - $response" >> "$AUTH_LOG"
  else
    echo -e "✅ $email - $server - Авторизация успешна"
  fi

  return $status
}

# Чтение CSV и проверка авторизации
mapfile -t valid_accounts < <(
  while IFS=',' read -r src_email src_server src_pass dst_email dst_pass dst_server; do
    src_email=$(echo "$src_email" | tr -d '"')
    src_pass=$(echo "$src_pass" | tr -d '"')
    dst_email=$(echo "$dst_email" | tr -d '"')
    dst_pass=$(echo "$dst_pass" | tr -d '"')
    src_server=$(echo "$src_server" | tr -d '"')
    dst_server=$(echo "$dst_server" | tr -d '"')

    check_auth "$src_email" "$src_pass" "$src_server" && \
    check_auth "$dst_email" "$dst_pass" "$dst_server" && \
    echo "$src_email,$src_pass,$src_server,$dst_email,$dst_pass,$dst_server"
  done < "$ACCOUNTS_FILE"
)

echo
if [[ -s "$AUTH_LOG" ]]; then
  echo "⚠️ Некоторые ящики не прошли авторизацию:"
  cat "$AUTH_LOG"
  echo
fi

read -rp "🚀 Продолжить перенос для прошедших авторизацию? [y/N]: " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

echo
echo "🚚 Начало переноса: $(date)"
START_TIME=$(date +%s)
COUNTER=0

for line in "${valid_accounts[@]}"; do
  IFS=',' read -r src_email src_pass src_server dst_email dst_pass dst_server <<< "$line"

  LOG_FILE="$LOGS_DIR/$(echo "$src_email" | tr '@.' '__').log"
  echo "📦 Старт переноса: $src_email → $dst_email"

  (
    imapsync \
      --host1 "$src_server" --user1 "$src_email" --password1 "$src_pass" --ssl1 \
      --host2 "$dst_server" --user2 "$dst_email" --password2 "$dst_pass" --ssl2 \
      --automap --skipcrossduplicates --useuid \
      --nofoldersizes \
      --logfile "$LOG_FILE" \
      --progress \
      2>&1 | tee "$LOG_FILE"
  ) &

  ((COUNTER++))

  if (( COUNTER % MAX_PARALLEL == 0 )); then
    wait
  fi
done

wait

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
echo
echo "✅ Перенос завершён. ⏱ Время: $((DURATION / 60)) минут $((DURATION % 60)) секунд"
