# IMAP Mail Migration (imapsync in Docker)

## 🔧 Установка и запуск

```bash
chmod +x is.sh
./is.sh
```

Скрипт:

- Проверяет Docker и устанавливает при необходимости
- Загружает образ `gilleslamiral/imapsync`
- Проверяет авторизацию всех ящиков
- Показывает список удачных и неудачных попыток
- Запрашивает подтверждение
- Запускает перенос с логами

## 📁 Формат файла accounts.txt (CSV)

```
"src_email","src_imap","src_pass","dst_email","dst_pass","dst_imap"
"user1@example.com","imap.source.com","sourcepass","user1@dest.com","destpass","imap.dest.com"
```

Пароли можно указывать в кавычках, спецсимволы допустимы.

## 📂 Логи

Логи сохраняются в папке `logs/` по каждому ящику отдельно.
