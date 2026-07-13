### Установка зависимостей

```bash
# Debian/Ubuntu
sudo apt install postgresql-client

# CentOS/RHEL
sudo yum install postgresql

# macOS
brew install postgresql
```

## Настройка аутентификации

Скрипт использует файл `~/.pgpass` для безопасной аутентификации.

### Создание файла ~/.pgpass

```bash
touch ~/.pgpass
chmod 600 ~/.pgpass

echo "localhost:5432:*:backup_user:your_password" >> ~/.pgpass
```

Формат файла:

```
hostname:port:database:username:password
```

- `hostname` — адрес сервера PostgreSQL
- `port` — порт (обычно 5432)
- `database` — имя базы или `*` для всех
- `username` — имя пользователя
- `password` — пароль

### Создание пользователя для бэкапов

```sql
CREATE ROLE backup_user WITH LOGIN PASSWORD 'your_password';

GRANT CONNECT ON DATABASE mydb TO backup_user;
GRANT USAGE ON SCHEMA public TO backup_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup_user;

GRANT pg_read_all_data TO backup_user;
```

## Использование

```bash
chmod +x backup_pg.sh
```

### Базовые команды

```bash
# Бэкап ВСЕХ баз данных
./backup_pg.sh

# Бэкап конкретной базы
./backup_pg.sh -d mydb

# Бэкап нескольких баз
./backup_pg.sh -d db1,db2,db3
```

### Настройка параметров

```bash
# Удалённый сервер
./backup_pg.sh -h db.example.com -p 5433 -u ops

# Свой каталог бэкапов и срок хранения
./backup_pg.sh -b /mnt/nas/backups -r 7

# Свой лог-файл
./backup_pg.sh -l /var/log/my_backup.log

# Исключить определённые базы
./backup_pg.sh -e "staging|test_.*"
```

### Все опции

| Опция | Описание | По умолчанию |
|-------|----------|--------------|
| `-h HOST` | Хост PostgreSQL | `localhost` |
| `-p PORT` | Порт PostgreSQL | `5432` |
| `-u USER` | Пользователь PostgreSQL | `postgres` |
| `-d DB` | База данных (через запятую) | Все пользовательские |
| `-b DIR` | Каталог бэкапов | `/backups` |
| `-r DAYS` | Срок хранения в днях | `14` |
| `-l FILE` | Путь к лог-файлу | `/var/log/pg_backup.log` |
| `-e PATTERN` | Исключить базы (grep-шаблон) | `template0\|template1` |
