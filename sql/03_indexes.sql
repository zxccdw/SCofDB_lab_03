\timing on
\echo '=== APPLY INDEXES ==='

-- Индекс 1: Составной индекс для фильтрации по статусу + сортировки по дате
CREATE INDEX idx_orders_status_created_at ON orders USING BTREE (status, created_at DESC);
-- Обоснование:
-- - Ускоряет Q1 (WHERE status = 'paid' ORDER BY created_at DESC)
-- - Ускоряет Q2 (WHERE status = 'paid' AND created_at >= ... AND created_at < ...)
-- - BTREE выбран т.к. поддерживает эффективную фильтрацию по равенству (status)
--   и range-запросы + сортировку по created_at
-- - Порядок колонок: сначала status (низкая селективность, ~5 значений),
--   потом created_at (высокая селективность) - это позволяет Index Only Scan

-- Индекс 2: Индекс на created_at для диапазонных запросов
CREATE INDEX idx_orders_created_at ON orders USING BTREE (created_at);
-- Обоснование:
-- - Ускоряет Q3 (WHERE created_at >= '2025-01-01' в JOIN)
-- - Ускоряет любые запросы с диапазонами дат или ORDER BY created_at
-- - BTREE эффективен для range queries и сортировки
-- - Используется когда нет фильтрации по status

-- Индекс 3: Foreign key для быстрых JOIN
CREATE INDEX idx_order_items_order_id ON order_items USING BTREE (order_id);
-- Обоснование:
-- - Критично ускоряет Q3 (JOIN order_items oi ON oi.order_id = o.id)
-- - Без индекса на FK происходит Seq Scan по 400k строк order_items
-- - BTREE для точного поиска по равенству (equi-join)
-- - Ускоряет JOIN с ~400k строк до Index Scan

-- Индекс 4: user_id для фильтрации заказов по пользователю
CREATE INDEX idx_orders_user_id ON orders USING BTREE (user_id);
-- Обоснование:
-- - Ускоряет Q4 (WHERE user_id = ...)
-- - Ускоряет любые запросы "заказы пользователя"
-- - BTREE для поиска по равенству
-- - Типичный паттерн в API: GET /users/{id}/orders

-- Индекс 5 (опциональный): BRIN для больших таблиц с упорядоченными данными
CREATE INDEX idx_orders_created_at_brin ON orders USING BRIN (created_at) WITH (pages_per_range = 128);
-- Обоснование:
-- - Компактная альтернатива BTREE индексу на created_at
-- - Эффективен т.к. данные упорядочены по времени создания
-- - Занимает в ~100-1000 раз меньше места чем BTREE
-- - Хорош для очень больших таблиц (миллионы строк)
-- - Может быть медленнее BTREE, но экономит память

ANALYZE;

\echo 'Indexes created successfully!'
