\timing on
\echo '=== PARTITION ORDERS BY DATE (Simplified) ==='

-- Упрощенный подход: создаем партиционированную таблицу как orders_p
-- Оригинальная orders остается для сравнения

DROP TABLE IF EXISTS orders_p CASCADE;

-- Создаем партиционированную таблицу
CREATE TABLE orders_p (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'created',
    total_amount DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

\echo 'Partitioned table orders_p created'

-- Создаем партиции по кварталам (2024-2026)
CREATE TABLE orders_p_2024_q1 PARTITION OF orders_p FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');
CREATE TABLE orders_p_2024_q2 PARTITION OF orders_p FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');
CREATE TABLE orders_p_2024_q3 PARTITION OF orders_p FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');
CREATE TABLE orders_p_2024_q4 PARTITION OF orders_p FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

CREATE TABLE orders_p_2025_q1 PARTITION OF orders_p FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');
CREATE TABLE orders_p_2025_q2 PARTITION OF orders_p FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');
CREATE TABLE orders_p_2025_q3 PARTITION OF orders_p FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE orders_p_2025_q4 PARTITION OF orders_p FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');

CREATE TABLE orders_p_2026_q1 PARTITION OF orders_p FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE orders_p_2026_q2 PARTITION OF orders_p FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

\echo 'Partitions created'

-- Копируем данные
INSERT INTO orders_p SELECT id, user_id, status, total_amount, created_at FROM orders;

\echo 'Data migrated'

-- Создаем индексы
CREATE INDEX idx_orders_p_status_created_at ON orders_p USING BTREE (status, created_at DESC);
CREATE INDEX idx_orders_p_created_at ON orders_p USING BTREE (created_at);
CREATE INDEX idx_orders_p_user_id ON orders_p USING BTREE (user_id);

\echo 'Indexes created'

ANALYZE orders_p;

-- Проверка
SELECT COUNT(*) as total_rows FROM orders_p;

\echo '--- Partition Pruning Demo: Query touches only Q1 2025 partition ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM orders_p
WHERE created_at >= '2025-01-01' AND created_at < '2025-04-01';

\echo 'Partitioning demo complete!'
