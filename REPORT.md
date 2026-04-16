# Отчёт по лабораторной работе №3
## Диагностика и оптимизация маркетплейса

**Студент:** Клычков Степан Сергеевич
**Группа:** БПМ-22-ПО-2
**Дата:** 12.04.2026

## 1. Исходные данные
### 1.1 Использованная схема
Использована схема из Lab 2 (`backend/migrations/001_init.sql`) с восстановленным триггером `check_order_not_already_paid` из Lab 1.

Основные таблицы:
- `users` - пользователи (id, email, name, created_at)
- `orders` - заказы (id, user_id, status, total_amount, created_at)
- `order_items` - позиции заказов (id, order_id, product_name, price, quantity)
- `order_status_history` - история изменения статусов

### 1.2 Объём данных
После seed-скрипта (`01_seed_100k.sql`):
- **users**: 10,000 записей
- **orders**: 100,000 записей (даты с 2024-01-01 по 2026-01-01)
- **order_items**: 400,000 записей (1-4 позиции на заказ)
- **order_status_history**: 100,000+ записей

**Важно**: Оригинальный seed-скрипт зависал на часы из-за триггера `recalculate_order_total`, срабатывающего на каждую из 400k вставок. Решение: временное отключение триггера во время массовой загрузки.

## 2. Найденные медленные запросы (до оптимизации)

### Запрос №1: Фильтрация по статусу + сортировка
```sql
SELECT id, user_id, status, total_amount, created_at
FROM orders
WHERE status = 'paid'
ORDER BY created_at DESC
LIMIT 100;
```

**EXPLAIN ANALYZE:**
- **Seq Scan** на всей таблице orders (100k строк)
- **Sort** на 49,979 отфильтрованных строк
- **Execution Time: 6.7ms**

**Почему медленно:**
- Полный скан таблицы для поиска ~50% строк
- Сортировка большого объема данных в памяти
- Отсутствие индексов

### Запрос №2: Диапазон дат + статус
```sql
SELECT COUNT(*), SUM(total_amount)
FROM orders
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at < '2025-12-31';
```

**EXPLAIN ANALYZE:**
- **Seq Scan** с фильтрацией по двум условиям
- Прочитано 100k строк, отфильтровано 25,090
- **Execution Time: 6.4ms**

**Почему медленно:**
- Нет индекса для диапазонных запросов по дате
- Нет составного индекса для комбинации условий

### Запрос №3: JOIN + GROUP BY + агрегация
```sql
SELECT o.id, o.status, COUNT(oi.id) as items_count,
       SUM(oi.price * oi.quantity) as total
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.created_at >= '2025-01-01'
GROUP BY o.id, o.status
ORDER BY total DESC
LIMIT 20;
```

**EXPLAIN ANALYZE:**
- **Seq Scan** на `order_items` (400k строк)
- **Hash Join** на большом объеме данных
- **HashAggregate** с 24MB памяти
- **Execution Time: 134.4ms** ⚠️ Самый медленный!

**Почему медленно:**
- Отсутствие FK индекса на `order_items.order_id`
- Полный скан 400k строк для JOIN
- Тяжелая агрегация

### Запрос №4: Поиск по user_id
```sql
SELECT id, status, total_amount, created_at
FROM orders
WHERE user_id = '...'
ORDER BY created_at DESC;
```

**EXPLAIN ANALYZE:**
- **Seq Scan** по всем 100k строкам
- Найдено только 11 записей
- **Execution Time: 2.7ms**

**Почему медленно:**
- Нет индекса на `user_id`
- Очень низкая селективность (11/100000)

## 3. Добавленные индексы и обоснование типа

### Индекс №1: Составной индекс status + created_at
```sql
CREATE INDEX idx_orders_status_created_at
ON orders USING BTREE (status, created_at DESC);
```
- **Ускоряет**: Q1 (WHERE status + ORDER BY created_at), Q2 (status + date range)
- **Тип BTREE**: поддерживает фильтрацию по равенству (status) + range queries + сортировку
- **Порядок колонок**: `status` первым (низкая кардинальность ~5 значений), затем `created_at` (высокая кардинальность)
- Позволяет **Index Scan** вместо Seq Scan + Sort

### Индекс №2: Индекс на created_at
```sql
CREATE INDEX idx_orders_created_at
ON orders USING BTREE (created_at);
```
- **Ускоряет**: Q3 (WHERE created_at >= ... в JOIN), любые диапазонные запросы по дате
- **Тип BTREE**: эффективен для range queries и ORDER BY
- Используется когда нет фильтрации по status

### Индекс №3: FK индекс на order_items
```sql
CREATE INDEX idx_order_items_order_id
ON order_items USING BTREE (order_id);
```
- **Ускоряет**: Q3 (JOIN order_items ON order_id)
- **Тип BTREE**: оптимален для equi-join
- **Критично**: без индекса на FK происходит Seq Scan по 400k строк при каждом JOIN

### Индекс №4: Индекс на user_id
```sql
CREATE INDEX idx_orders_user_id
ON orders USING BTREE (user_id);
```
- **Ускоряет**: Q4 (WHERE user_id = ...), API endpoint GET /users/{id}/orders
- **Тип BTREE**: точный поиск по равенству

### Индекс №5 (опциональный): BRIN для больших объемов
```sql
CREATE INDEX idx_orders_created_at_brin
ON orders USING BRIN (created_at) WITH (pages_per_range = 128);
```
- **Альтернатива** BTREE индексу на created_at
- **Тип BRIN**: компактный (в ~100-1000 раз меньше BTREE)
- Эффективен т.к. данные упорядочены по времени создания
- Занимает минимум памяти при хорошей производительности на больших таблицах

## 4. Замеры до/после индексов

| Запрос | До (ms) | После (ms) | Ускорение | Изменение плана |
|--------|---------|------------|-----------|-----------------|
| **Q1** (status + sort) | 6.7 | **1.2** | **5.6x** ✅ | Seq Scan → Index Scan |
| **Q2** (status + date) | 6.4 | 8.6 | 0.7x ⚠️ | Seq Scan → Bitmap Index Scan |
| **Q3** (JOIN + GROUP BY) | 134.4 | 167.9 | 0.8x ❌ | Seq Scan на order_items остался |
| **Q4** (user_id) | 2.7 | **0.1** | **27x** ✅ | Seq Scan → Bitmap Index Scan |

**Выводы:**
- ✅ **Q1 и Q4**: значительное ускорение благодаря Index Scan
- ⚠️ **Q2**: небольшое замедление из-за Bitmap Heap Scan overhead (при малом объеме данных индекс может быть дороже)
- ❌ **Q3**: индексы не помогли - планировщик все равно выбирает Seq Scan на 400k строк `order_items` для JOIN

## 5. Партиционирование `orders` по дате
### 5.1 Выбранная стратегия
**RANGE партиционирование по `created_at` (по кварталам)**

Создано 10 партиций:
- 2024: Q1, Q2, Q3, Q4
- 2025: Q1, Q2, Q3, Q4
- 2026: Q1, Q2

### 5.2 Реализация
**Подход:** Создана партиционированная таблица `orders_p` рядом с оригинальной `orders` для демонстрации.

```sql
CREATE TABLE orders_p (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'created',
    total_amount DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Создание партиций
CREATE TABLE orders_p_2025_q1 PARTITION OF orders_p
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
-- ... и т.д.

-- Миграция данных
INSERT INTO orders_p SELECT * FROM orders; -- 100k строк за 175ms

-- Индексы
CREATE INDEX ON orders_p (status, created_at DESC);
CREATE INDEX ON orders_p (created_at);
CREATE INDEX ON orders_p (user_id);
```

**Важные особенности:**
- PRIMARY KEY должен включать partition key (`id, created_at`)
- Foreign keys из других таблиц требуют сложной настройки UNIQUE constraint
- Для демонстрации FK не были восстановлены

### 5.3 Проверка эффекта - Partition Pruning в действии!
**Запрос к Q1 2025:**
```sql
SELECT COUNT(*) FROM orders_p
WHERE created_at >= '2025-01-01' AND created_at < '2025-04-01';
```

**План:**
```
Seq Scan on orders_p_2025_q1 orders_p
  Filter: (created_at >= '2025-01-01' AND created_at < '2025-04-01')
  Execution Time: 1.28ms
```

✅ **Partition Pruning сработал!** Планировщик читает **только партицию `orders_p_2025_q1`** (12,383 строк) вместо всей таблицы (100k строк)!

## 6. Итоговые замеры (после партиционирования)

| Запрос | Baseline | После индексов | После партиционирования | Итого ускорение |
|--------|----------|----------------|-------------------------|-----------------|
| **Q1** (status + sort) | 6.7ms | 1.2ms | **0.38ms** | **17.6x** 🚀 |
| **Q2** (status + date) | 6.4ms | 8.6ms | **6.2ms** | **1.03x** |
| **Q3** (JOIN + GROUP BY) | 134.4ms | 167.9ms | **168.7ms** | 0.8x ❌ |
| **Q4** (user_id) | 2.7ms | 0.1ms | **0.2ms** | **13.5x** 🚀 |

**Наблюдения:**
- **Q1**: дополнительное ускорение благодаря Append (сканирование начинается с последних партиций)
- **Q2**: Partition Pruning читает только 4 партиции 2025 года (~50k строк) вместо 100k
- **Q3**: партиционирование не помогло т.к. узкое место - Seq Scan на `order_items` (не партиционирована)
- **Q4**: стабильное ускорение, Append сканирует только нужные партиции

## 7. Что удалось исправить

### ✅ Seq Scan → Index Scan (Q1, Q4)
- **Проблема**: Полный скан 100k строк для поиска ~11-50k записей
- **Решение**: Составной индекс `(status, created_at)` и индекс `(user_id)`
- **Результат**: 5-27x ускорение

### ✅ Partition Pruning (Q2)
- **Проблема**: Чтение всех 100k строк для запросов по диапазону дат
- **Решение**: RANGE партиционирование по кварталам
- **Результат**: Планировщик читает только нужные партиции (4 из 10)

### ✅ Оптимизация seed-скрипта
- **Проблема**: Генерация 100k заказов зависала на часы
- **Решение**: Временное отключение триггера `recalculate_order_total` во время bulk insert
- **Результат**: Вставка 400k order_items за 3 секунды вместо часов

## 8. Что не удалось исправить только индексами

### ❌ Seq Scan при высокой селективности (Q2, Q3)
**Проблема**: Планировщик выбирает Seq Scan когда фильтр выбирает >10-15% строк.

**Q2**: Фильтр `status = 'paid' AND created_at IN 2025` выбирает 25,090 из 100,000 строк (~25%).
- Index Scan потребовал бы 25k random I/O операций
- Seq Scan читает всю таблицу последовательно (~2k pages)
- **Планировщик правильно выбрал Seq Scan!**

**Решение**: Только партиционирование (уменьшение объема сканируемых данных).

### ❌ Тяжелый JOIN + GROUP BY (Q3: 134ms → 168ms)
**Проблема**: Узкое место - Seq Scan на `order_items` (400k строк) для JOIN.

**Почему индекс не помог:**
- FK индекс создан: `idx_order_items_order_id`
- Но планировщик все равно выбирает Seq Scan
- Причина: JOIN выбирает ~50% строк (200k из 400k) - Seq Scan эффективнее

**Что не сработало:**
- Индексы на orders (применяются, но JOIN все равно медленный)
- Партиционирование orders (order_items не партиционирована)

**Реальные решения:**
1. **Партиционирование order_items** по order_id или created_at
2. **Материализованное представление** с pre-aggregated данными
3. **Переписывание запроса** с фильтрацией order_items до JOIN
4. **Денормализация**: хранить items_count в таблице orders

### ❌ Bitmap Heap Scan overhead (Q2)
На малых объемах данных Bitmap Index Scan может быть медленнее Seq Scan из-за:
- Построения bitmap в памяти
- Heap Fetch для каждой страницы
- Random I/O вместо Sequential

**Решение**: На больших таблицах (>1M строк) эффект индексов проявится сильнее.

## 9. Выводы

### 1. Индексы эффективны при низкой селективности (<10% строк)
Индексы дали 5-27x ускорение для запросов, выбирающих малый процент строк (Q1: 100 из 50k, Q4: 11 из 100k). При высокой селективности (>15%) планировщик правильно выбирает Seq Scan.

### 2. Составные индексы - порядок колонок важен!
Индекс `(status, created_at DESC)` эффективен потому что:
- `status` - первым (низкая кардинальность, фильтрация)
- `created_at DESC` - вторым (высокая кардинальность, сортировка)
- Позволяет Index Only Scan без обращения к heap

### 3. FK индексы критичны для JOIN
Без индекса на `order_items.order_id` каждый JOIN требует Seq Scan по 400k строк. Индекс на FK - базовая оптимизация, но не панацея при высокой селективности.

### 4. Партиционирование + Partition Pruning для диапазонных запросов
RANGE партиционирование по времени:
- Уменьшает объем сканируемых данных (4 партиции вместо 10)
- Эффективно для запросов с `WHERE created_at BETWEEN ...`
- PRIMARY KEY должен включать partition key
- Усложняет FK constraints

### 5. EXPLAIN ANALYZE - обязательный инструмент
Метрики до/после показали:
- Где индексы дали эффект (Q1, Q4)
- Где не помогли (Q2, Q3) и почему
- Планировщик иногда "умнее" наших ожиданий (Seq Scan может быть быстрее Index Scan)

### 6. Триггеры могут убить производительность массовых операций
Триггер `recalculate_order_total` на каждой строке превратил вставку 400k записей из 3 секунд в часы. Решение: временное отключение триггеров + batch UPDATE после загрузки.

### 7. Реальная оптимизация часто требует комплексного подхода
Для Q3 (JOIN + GROUP BY) одних индексов недостаточно. Нужны:
- Партиционирование обеих таблиц
- Материализованные представления
- Денормализация
- Переписывание запросов

**Итоговый практический совет:** Всегда начинайте с `EXPLAIN ANALYZE`, создавайте индексы на FK и часто фильтруемые колонки, но помните - индексы не универсальное решение. Иногда проблема в архитектуре запроса или схемы БД.
