#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Postra - Update Script
# =============================================================================
# Usage: bash update.sh
# Pulls the latest image and restarts the app container.
# Infrastructure services (Postgres, Redis, Temporal) are NOT restarted.
# =============================================================================

INSTALL_DIR="/docker/postra"
COMPOSE_FILE="${INSTALL_DIR}/deploy/docker-compose.prod.yaml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; }
info()  { echo -e "${CYAN}[INFO]${NC} $1"; }

# ---------------------------------------------------------------------------
# Wait for healthcheck
# ---------------------------------------------------------------------------
wait_healthy() {
  local container="$1"
  local timeout="${2:-120}"
  local elapsed=0

  info "Waiting for ${container} to be healthy (timeout: ${timeout}s)..."

  while [ $elapsed -lt "$timeout" ]; do
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "${container}" 2>/dev/null || echo "not_found")

    case "$status" in
      healthy)
        log "${container} is healthy"
        return 0
        ;;
      unhealthy)
        err "${container} is unhealthy. Showing logs:"
        docker logs "${container}" --tail 30
        return 1
        ;;
    esac

    sleep 3
    elapsed=$((elapsed + 3))
  done

  err "${container} did not become healthy within ${timeout}s."
  docker logs "${container}" --tail 30
  return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  info "=== Postra Update ==="
  echo ""

  # Check compose file exists
  if [ ! -f "${COMPOSE_FILE}" ]; then
    err "Compose file not found: ${COMPOSE_FILE}"
    err "Are you sure Postra is installed?"
    exit 1
  fi

  cd "${INSTALL_DIR}/deploy"

  # Update repo (for dynamicconfig changes, compose file updates, etc.)
  info "Pulling latest code..."
  cd "${INSTALL_DIR}"
  git pull origin igk-branding
  cd "${INSTALL_DIR}/deploy"

  # Pull latest image
  info "Pulling latest Docker image..."
  docker compose -f docker-compose.prod.yaml pull postiz

  # Show current vs new image digest
  info "Restarting Postra (brief downtime expected)..."
  docker compose -f docker-compose.prod.yaml up -d --no-deps --force-recreate postiz

  # Wait for health
  if wait_healthy postiz 180; then
    # Verify HTTPS
    local domain
    domain=$(grep '^DOMAIN=' .env | cut -d= -f2)

    sleep 3
    local http_code
    http_code=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "https://${domain}" 2>/dev/null || echo "000")

    echo ""
    echo "=========================================="
    echo -e "${GREEN} Update complete!${NC}"
    echo "=========================================="
    echo "  HTTP Status: ${http_code}"
    echo "  URL: https://${domain}"
    echo ""

    # Show recent logs
    info "Recent logs:"
    docker compose -f docker-compose.prod.yaml logs postiz --tail 10
  else
    err "Update may have failed. Check the logs:"
    echo "  docker compose -f ${COMPOSE_FILE} logs postiz"
    exit 1
  fi
}

main "$@"
