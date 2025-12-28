# Update note: kairon-ops.sh

The kairon-ops.sh script still references the old "dev" environment which no longer exists after the deployment simplification.

## Current State

kairon-ops.sh has `--dev` flag that:
- References `N8N_DEV_API_KEY`, `N8N_DEV_API_URL` (from old dev setup)
- References `postgres-dev`, `kairon_dev` database (old dev database)
- Sets up SSH tunnels for remote dev (no longer needed)

## Recommendation

Keep kairon-ops.sh as-is for now, but:
1. Update documentation to clarify `--dev` is for local operations
2. Remove references to "remote dev" (no longer exists)
3. Keep `--prod` for production operations
4. Document that `--dev` is equivalent to running against localhost:5679

## Future Work

Consider updating kairon-ops.sh to:
- Remove `--dev` flag entirely (keep only production operations)
- Add a `--help` flag
- Simplify to only production operations
- Use `rdev` or direct SSH for remote operations

The script is still useful for production operations (status, backup, db-query), so we shouldn't remove it entirely.
