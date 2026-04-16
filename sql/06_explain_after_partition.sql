\timing on
\echo '=== AFTER PARTITIONING ==='
-- ВАЖНО: этот файл использует таблицу orders_p.
-- Перед запуском выполните: sql/05_partition_orders_simple.sql
-- (а НЕ 05_partition_orders.sql, который переименовывает таблицу в orders)

SET max_parallel_workers_per_gather = 0;
SET work_mem = '32MB';

-- Используем партиционированную таблицу orders_p

\echo '--- Q1: Фильтрация по статусу + сортировка по дате (на orders_p) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, status, total_amount, created_at
FROM orders_p
WHERE status = 'paid'
ORDER BY created_at DESC
LIMIT 100;

\echo '--- Q2: Фильтрация по статусу + диапазону дат (на orders_p с partition pruning) ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), SUM(total_amount)
FROM orders_p
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at < '2026-01-01'; -- включает весь 2025 год (< '2025-12-31' не покрывает 31 декабря)

\echo '--- Q3: JOIN с партиционированной таблицей ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, COUNT(oi.id) as items_count, SUM(oi.price * oi.quantity) as total
FROM orders_p o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.created_at >= '2025-01-01'
GROUP BY o.id, o.status
ORDER BY total DESC
LIMIT 20;

\echo '--- Q4: Поиск по user_id на партиционированной таблице ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, total_amount, created_at
FROM orders_p
WHERE user_id = (SELECT id FROM users LIMIT 1)
ORDER BY created_at DESC;

\echo '--- Демонстрация Partition Pruning: запрос только к Q1 2025 ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), AVG(total_amount)
FROM orders_p
WHERE created_at >= '2025-01-01' AND created_at < '2025-04-01';
