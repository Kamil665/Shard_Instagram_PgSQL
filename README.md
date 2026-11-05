# Логическое шардирование PostgreSQL (как у Instagram)

Полный рабочий пример **логического шардирования** в стиле Instagram на чистом PostgreSQL.

## Архитектура

```
Клиент
  ↓
Приложение / Proxy (определяет logical_shard по user_id)
  ↓
shard_map → physical_host + database
  ↓
PostgreSQL (один из многих инстансов)
  └── schema/database shard_XXXX
        ├── users
        ├── media
        └── follows
```

### Ключевые принципы

- Каждый `user_id` всегда попадает в **один и тот же** логический шард
- Логических шардов много (в примере 4, в продакшене обычно 1024–4096)
- Физических серверов меньше, чем логических шардов
- Приложение **никогда** не делает JOIN между разными шардами
- Перенос шарда на другой сервер = просто обновление записи в `shard_map`

---

## Быстрый старт

1. Откройте `psql` или pgAdmin
2. Выполните весь скрипт из файла `logical_sharding.sql`
3. Проверьте работу:

```sql
-- Куда попал пользователь
SELECT * FROM shard_meta.get_shard_info(1001);

-- Данные пользователя
SELECT * FROM shard_meta.get_user(1001);

-- Медиа пользователя
SELECT * FROM shard_meta.get_user_media(1001);
```

---

## Структура

| Объект | Назначение |
|--------|----------|
| `shard_meta.shard_map` | Таблица маршрутизации (logical → physical) |
| `shard_meta.get_logical_shard(user_id)` | Вычисляет номер логического шарда |
| `shard_meta.get_shard_info(user_id)` | Возвращает host + port + database + schema |
| `shard_meta.insert_user(...)` | Вставляет пользователя в правильный шард |
| `shard_meta.insert_media(...)` | Вставляет медиа в правильный шард |
| `shard_meta.get_user(...)` | Читает пользователя |
| `shard_meta.get_user_media(...)` | Читает медиа пользователя |
| `shard_0000` … `shard_0003` | Логические шарды (схемы) |

---

## Как это работает

### 1. Определение шарда

```sql
SELECT shard_meta.get_logical_shard(1001);
-- Например: 0
```

Используется встроенная функция `hashtext()`:

```sql
abs(hashtext(user_id::text)) % 4
```

### 2. Получение информации о физическом расположении

```sql
SELECT * FROM shard_meta.get_shard_info(1001);
```

Результат:

| logical_shard_id | physical_host | physical_port | database_name | schema_name |
|------------------|---------------|---------------|---------------|-------------|
| 0                | localhost     | 5432          | postgres      | shard_0000  |

### 3. Приложение использует эти данные

```python
info = get_shard_info(user_id)

conn = psycopg2.connect(
    host=info.physical_host,
    port=info.physical_port,
    dbname=info.database_name
)

# Дальше работаем только с нужной схемой
```

---

## Расширение до реального продакшена

### Больше шардов

Просто измените количество:

```sql
-- Было
abs(hashtext(user_id::text)) % 4

-- Стало (например 2048)
abs(hashtext(user_id::text)) % 2048
```

И добавьте соответствующие записи в `shard_map`.

### Несколько физических серверов

```sql
INSERT INTO shard_meta.shard_map 
    (logical_shard_id, physical_host, database_name, schema_name) 
VALUES
(0,  'pg-01.prod', 'shard_db', 'public'),
(1,  'pg-01.prod', 'shard_db', 'public'),
(2,  'pg-02.prod', 'shard_db', 'public'),
(3,  'pg-02.prod', 'shard_db', 'public');
```

### Перенос шарда (rebalancing)

1. Создаёте новый физический инстанс
2. Копируете данные логического шарда
3. Обновляете запись в `shard_map`
4. Плавно переключаете трафик

---

## Что дальше можно добавить

- Функцию `follow` / `unfollow`
- Двойную запись во время миграции шарда
- Версию на Python / Go / Node.js с реальным подключением
- Использование `Citus` или `Postgres FDW` вместо ручного роутинга
- Мониторинг распределения данных по шардам

---

## Полезные запросы

```sql
-- Распределение пользователей по шардам
SELECT 
    schema_name,
    (SELECT count(*) FROM shard_0000.users) FILTER (WHERE schema_name = 'shard_0000') +
    (SELECT count(*) FROM shard_0001.users) FILTER (WHERE schema_name = 'shard_0001') +
    (SELECT count(*) FROM shard_0002.users) FILTER (WHERE schema_name = 'shard_0002') +
    (SELECT count(*) FROM shard_0003.users) FILTER (WHERE schema_name = 'shard_0003')
FROM shard_meta.shard_map;

-- Более простой вариант
SELECT 'shard_0000' AS shard, count(*) FROM shard_0000.users
UNION ALL SELECT 'shard_0001', count(*) FROM shard_0001.users
UNION ALL SELECT 'shard_0002', count(*) FROM shard_0002.users
UNION ALL SELECT 'shard_0003', count(*) FROM shard_0003.users;
```

---

## Лицензия

MIT. Можно свободно использовать и модифицировать.
