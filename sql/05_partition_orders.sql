\timing on
\echo '=== PARTITION ORDERS BY DATE ==='

BEGIN;

-- Шаг 1: Создаем партиционированную таблицу
-- ВАЖНО: PRIMARY KEY должен включать partition key (created_at)
-- UNIQUE constraint на id нужен для foreign keys из других таблиц
CREATE TABLE orders_partitioned (
    id UUID NOT NULL,
    user_id UUID NOT NULL,
    status VARCHAR(50) NOT NULL DEFAULT 'created',
    total_amount DECIMAL(10, 2) NOT NULL DEFAULT 0.00,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    
    PRIMARY KEY (id, created_at),
    UNIQUE (id),
    CONSTRAINT total_amount_non_negative CHECK (total_amount >= 0)
) PARTITION BY RANGE (created_at);

\echo 'Partitioned table created'

-- Шаг 2: Создаем партиции по кварталам (2024-2026)

-- 2024
CREATE TABLE orders_2024_q1 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

CREATE TABLE orders_2024_q2 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-04-01') TO ('2024-07-01');

CREATE TABLE orders_2024_q3 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-07-01') TO ('2024-10-01');

CREATE TABLE orders_2024_q4 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2024-10-01') TO ('2025-01-01');

-- 2025
CREATE TABLE orders_2025_q1 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-01-01') TO ('2025-04-01');

CREATE TABLE orders_2025_q2 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-04-01') TO ('2025-07-01');

CREATE TABLE orders_2025_q3 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');

CREATE TABLE orders_2025_q4 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');

-- 2026
CREATE TABLE orders_2026_q1 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');

CREATE TABLE orders_2026_q2 PARTITION OF orders_partitioned
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

\echo 'Partitions created'

-- Шаг 3: Переносим данные
INSERT INTO orders_partitioned SELECT * FROM orders;

\echo 'Data migrated'

-- Проверяем количество записей
DO $$
DECLARE
    old_count INTEGER;
    new_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO old_count FROM orders;
    SELECT COUNT(*) INTO new_count FROM orders_partitioned;
    
    RAISE NOTICE 'Orders (old): %', old_count;
    RAISE NOTICE 'Orders (partitioned): %', new_count;
    
    IF old_count != new_count THEN
        RAISE EXCEPTION 'Data migration failed! Counts do not match.';
    END IF;
END $$;

-- Шаг 4: Заменяем таблицы
ALTER TABLE orders RENAME TO orders_old;
ALTER TABLE orders_partitioned RENAME TO orders;

\echo 'Tables swapped'

-- Шаг 5: FK на партиционированных таблицах
-- ВАЖНО: FK из других таблиц требует UNIQUE constraint,
-- но в партиционированной таблице UNIQUE должен включать partition key
-- Для демонстрации партиционирования оставляем FK только на users и statuses

ALTER TABLE orders ADD CONSTRAINT fk_orders_user 
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE;

ALTER TABLE orders ADD CONSTRAINT fk_orders_status 
    FOREIGN KEY (status) REFERENCES order_statuses(status);

-- FK из order_items и order_status_history не пересоздаются,
-- т.к. требуют UNIQUE(id, created_at) что усложняет схему
-- Приложение будет работать, т.к. репозитории не используют CASCADE

\echo 'Foreign keys configured'

-- Шаг 6: Пересоздаем индексы на партиционированной таблице
CREATE INDEX idx_orders_status_created_at ON orders USING BTREE (status, created_at DESC);
CREATE INDEX idx_orders_created_at ON orders USING BTREE (created_at);
CREATE INDEX idx_orders_user_id ON orders USING BTREE (user_id);
CREATE INDEX idx_orders_created_at_brin ON orders USING BRIN (created_at) WITH (pages_per_range = 128);

\echo 'Indexes recreated on partitioned table'

-- Шаг 7: Пересоздаем триггеры
CREATE OR REPLACE FUNCTION check_order_not_already_paid()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status = 'paid' AND (OLD.status IS NULL OR OLD.status != 'paid') THEN
        IF EXISTS (
            SELECT 1
            FROM order_status_history
            WHERE order_id = NEW.id AND status = 'paid'
        ) THEN
            RAISE EXCEPTION 'Order % is already paid', NEW.id;
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_check_order_not_already_paid
    BEFORE UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION check_order_not_already_paid();

CREATE OR REPLACE FUNCTION record_order_status_change()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.id, NEW.status, NEW.created_at);
    END IF;
    IF TG_OP = 'UPDATE' AND OLD.status != NEW.status THEN
        INSERT INTO order_status_history (order_id, status, changed_at)
        VALUES (NEW.id, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_record_order_status_change
    AFTER INSERT OR UPDATE ON orders
    FOR EACH ROW
    EXECUTE FUNCTION record_order_status_change();

\echo 'Triggers recreated'

-- Удаляем старую таблицу
DROP TABLE orders_old CASCADE;

\echo 'Old table dropped'

COMMIT;

-- Финальная аналитика
ANALYZE orders;

-- Проверка partition pruning
\echo '--- Partition Pruning Test ---'
EXPLAIN (ANALYZE, BUFFERS)
SELECT COUNT(*) FROM orders
WHERE created_at >= '2025-01-01' AND created_at < '2025-04-01';

\echo 'Partitioning complete!'
