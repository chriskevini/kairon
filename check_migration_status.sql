-- Check if migration 002 has been applied

-- Check 1: Does activity_category enum exist?
SELECT EXISTS (
  SELECT 1 FROM pg_type WHERE typname = 'activity_category'
) AS enum_exists;

-- Check 2: What columns does activity_log have?
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_name = 'activity_log'
  AND column_name IN ('category_id', 'category')
ORDER BY column_name;

-- Check 3: Sample activity_log data
SELECT id, timestamp, category_id, category, description
FROM activity_log
ORDER BY timestamp DESC
LIMIT 5;
