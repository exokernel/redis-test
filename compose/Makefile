.PHONY: up down reset clean status insert verify backup upgrade rollback logs

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

up:
	docker-compose up -d redis-master redis-replica-1 sentinel-1 sentinel-2

down:
	docker-compose --profile v82 down

# Remove containers AND volumes — full clean slate
reset:
	docker-compose --profile v82 down -v
	rm -rf backups/* .keycount .last_backup

# Remove saved backups and state files only
clean:
	rm -rf backups/* .keycount .last_backup

# ── Observability ─────────────────────────────────────────────────────────────

status:
	@bash scripts/status.sh

logs:
	docker-compose --profile v82 logs -f

# ── Data ──────────────────────────────────────────────────────────────────────

# Insert 100 test keys (override: make insert COUNT=500)
insert:
	@bash scripts/insert-data.sh $(or $(COUNT),100)

# Verify all inserted keys are present and correct
verify:
	@bash scripts/verify-data.sh

# BGSAVE on current master + copy dump.rdb to ./backups/<timestamp>/
backup:
	@bash scripts/rdb-backup.sh

# ── Upgrade / rollback ────────────────────────────────────────────────────────

# Interactive Option A upgrade walkthrough
upgrade:
	@bash scripts/upgrade-option-a.sh

# Restore from a saved RDB backup to Redis 6.2
rollback:
	@bash scripts/rollback.sh
