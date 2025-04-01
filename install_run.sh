#!/bin/bash

set -e

echo "🔍 Проверка наличия Docker..."
if ! command -v docker &> /dev/null; then
    echo "🚀 Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    echo "✅ Docker установлен. Перезагрузите систему и повторите запуск скрипта."
    exit 0
fi

echo "✅ Docker установлен"

echo "📦 Проверка образа imapsync..."
if [[ "$(docker images -q gilleslamiral/imapsync 2> /dev/null)" == "" ]]; then
    echo "⬇️ Загрузка образа imapsync..."
    docker pull gilleslamiral/imapsync
else
    echo "✅ Образ imapsync уже загружен"
fi

# Создание необходимых директорий и файлов
mkdir -p logs

if [ ! -f accounts.txt ]; then
    echo "ℹ️ Создаю пустой файл accounts.txt"
    cat <<EOF > accounts.txt
"email1@example.com";"password1";"imap.source.com";"email1@target.com";"password2";"imap.target.com"
EOF
fi

# Проверка is.sh
if [ ! -f is.sh ]; then
    echo "❌ Файл is.sh не найден!"
    exit 1
fi

# Запуск
echo "🚀 Запуск переноса..."
docker run --rm \
  -u $(id -u):$(id -g) \
  -v "$(pwd):/data" \
  gilleslamiral/imapsync \
  /bin/bash /data/is.sh
