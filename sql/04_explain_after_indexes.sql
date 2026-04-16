\timing on
\echo '=== AFTER INDEXES ==='

SET max_parallel_workers_per_gather = 0;
SET work_mem = '32MB';

\echo '--- Q1: Фильтрация по статусу + сортировка по дате ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, user_id, status, total_amount, created_at
FROM orders
WHERE status = 'paid'
ORDER BY created_at DESC
LIMIT 100;

\echo '--- Q2: Фильтрация по статусу + диапазону дат ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*), SUM(total_amount)
FROM orders
WHERE status = 'paid'
  AND created_at >= '2025-01-01'
  AND created_at < '2026-01-01'; -- включает весь 2025 год

\echo '--- Q3: JOIN + GROUP BY + агрегация ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT o.id, o.status, COUNT(oi.id) as items_count, SUM(oi.price * oi.quantity) as total
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
WHERE o.created_at >= '2025-01-01'
GROUP BY o.id, o.status
ORDER BY total DESC
LIMIT 20;

\echo '--- Q4: Поиск по user_id + сортировка ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, status, total_amount, created_at
FROM orders
WHERE user_id = (SELECT id FROM users LIMIT 1)
ORDER BY created_at DESC;
