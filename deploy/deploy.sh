#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Postra - First-time Deployment Script
# =============================================================================
# Usage: bash deploy.sh
# Run this on the VPS to set up Postra for the first time.
# =============================================================================

REPO_URL="https://github.com/KlevisGolemi/igk-post-app.git"
REPO_BRANCH="igk-branding"
INSTALL_DIR="/docker/postra"
COMPOSE_FILE="${INSTALL_DIR}/deploy/docker-compose.prod.yaml"

# Colors
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
# 1. Pre-flight checks
# ---------------------------------------------------------------------------
preflight() {
  info "Running pre-flight checks..."

  if ! command -v docker &>/dev/null; then
    err "Docker is not installed. Install it first: https://docs.docker.com/engine/install/ubuntu/"
    exit 1
  fi

  if ! docker compose version &>/dev/null; then
    err "Docker Compose V2 is not available. Update Docker or install the compose plugin."
    exit 1
  fi

  if ! command -v openssl &>/dev/null; then
    err "openssl is not installed. Run: apt install -y openssl"
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    err "curl is not installed. Run: apt install -y curl"
    exit 1
  fi

  if ! command -v git &>/dev/null; then
    err "git is not installed. Run: apt install -y git"
    exit 1
  fi

  # Check available memory (warn if < 4GB)
  local mem_total_kb
  mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
  local mem_total_gb=$(( mem_total_kb / 1024 / 1024 ))
  if [ "$mem_total_gb" -lt 4 ]; then
    warn "Only ${mem_total_gb}GB RAM detected. Postra needs at least 4GB free."
  else
    log "RAM: ${mem_total_gb}GB detected"
  fi

  log "All pre-flight checks passed"
}

# ---------------------------------------------------------------------------
# 2. Traefik detection & setup
# ---------------------------------------------------------------------------
detect_traefik_container() {
  # Find any running container using a traefik image (regardless of container name)
  docker ps --format '{{.Names}}\t{{.Image}}' | grep -i 'traefik' | head -1 | cut -f1
}

detect_certresolver() {
  # Auto-detect the certresolver name from an existing Traefik container's labels or config
  local traefik_container="$1"

  if [ -z "$traefik_container" ]; then
    return
  fi

  # Method 1: Check other containers' labels for certresolver names
  local resolver
  resolver=$(docker ps --format '{{.Names}}' | while read -r name; do
    docker inspect --format='{{range $k,$v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$name" 2>/dev/null \
      | grep -oP 'traefik\.http\.routers\.\w+\.tls\.certresolver=\K\S+' \
      | head -1
  done | head -1)

  if [ -n "$resolver" ]; then
    echo "$resolver"
    return
  fi

  # Method 2: Check Traefik's own static config (if mounted as a volume)
  resolver=$(docker exec "$traefik_container" cat /etc/traefik/traefik.yml 2>/dev/null \
    | grep -A2 'certificatesResolvers:' \
    | grep -oP '^\s+\K[a-zA-Z0-9_-]+(?=:)' \
    | head -1)

  if [ -n "$resolver" ]; then
    echo "$resolver"
    return
  fi

  # Method 3: Try traefik.yaml variant
  resolver=$(docker exec "$traefik_container" cat /etc/traefik/traefik.yaml 2>/dev/null \
    | grep -A2 'certificatesResolvers:' \
    | grep -oP '^\s+\K[a-zA-Z0-9_-]+(?=:)' \
    | head -1)

  if [ -n "$resolver" ]; then
    echo "$resolver"
  fi
}

ensure_traefik_network() {
  local traefik_container="$1"

  # Create traefik-network if it doesn't exist
  if ! docker network inspect traefik-network &>/dev/null; then
    info "Creating traefik-network..."
    docker network create traefik-network
  fi

  # Connect the existing Traefik container to traefik-network if not already on it
  if [ -n "$traefik_container" ]; then
    local on_network
    on_network=$(docker inspect --format='{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$traefik_container" 2>/dev/null)

    if echo "$on_network" | grep -q 'traefik-network'; then
      log "Traefik container '${traefik_container}' is already on traefik-network"
    else
      info "Connecting '${traefik_container}' to traefik-network..."
      docker network connect traefik-network "$traefik_container"
      log "Traefik container '${traefik_container}' connected to traefik-network"
    fi
  fi
}

check_ports_conflict() {
  # Check if ports 80/443 are already bound by Docker
  local port_owners
  port_owners=$(docker ps --format '{{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0:(80|443)->' || true)

  if [ -n "$port_owners" ]; then
    echo "$port_owners"
    return 0  # ports are in use
  fi
  return 1  # ports are free
}

setup_traefik() {
  info "Checking for Traefik..."

  # --- Case 1: A Traefik container is already running ---
  local traefik_container
  traefik_container=$(detect_traefik_container)

  if [ -n "$traefik_container" ]; then
    log "Traefik detected: container '${traefik_container}' is running"
    ensure_traefik_network "$traefik_container"

    # Auto-detect certresolver name
    local detected_resolver
    detected_resolver=$(detect_certresolver "$traefik_container")
    if [ -n "$detected_resolver" ]; then
      log "Detected certresolver: '${detected_resolver}'"
      DETECTED_CERTRESOLVER="$detected_resolver"
    else
      warn "Could not auto-detect certresolver name. Will use default 'letsencrypt'."
      warn "If your Traefik uses a different name (e.g. 'mytlschallenge'), set TRAEFIK_CERTRESOLVER in .env"
      DETECTED_CERTRESOLVER=""
    fi
    return 0
  fi

  # --- Case 2: No Traefik container, but ports 80/443 are occupied by Docker ---
  if check_ports_conflict; then
    err "Ports 80/443 are already in use by Docker containers:"
    docker ps --format '  {{.Names}}\t{{.Ports}}' | grep -E '0\.0\.0\.0:(80|443)->'
    echo ""
    err "Cannot install Traefik without freeing these ports."
    echo "Options:"
    echo "  1. Stop the container using ports 80/443 and re-run this script"
    echo "  2. If that IS your reverse proxy, create the network and connect it manually:"
    echo "     docker network create traefik-network"
    echo "     docker network connect traefik-network <your-proxy-container>"
    echo "     Then re-run this script."
    exit 1
  fi

  # --- Case 3: traefik-network exists but Traefik is stopped ---
  if docker network inspect traefik-network &>/dev/null; then
    warn "traefik-network exists but no Traefik container is running."
    echo ""
    read -rp "Start Traefik using the bundled config? [Y/n]: " answer
    answer=${answer:-Y}
    if [[ "$answer" =~ ^[Yy] ]]; then
      start_traefik
    else
      warn "Continuing without starting Traefik. Make sure your proxy is running."
    fi
    return 0
  fi

  # --- Case 4: No Traefik at all ---
  warn "No reverse proxy detected."
  echo ""
  echo "Postra needs Traefik (or another reverse proxy) for HTTPS."
  read -rp "Install Traefik now? [Y/n]: " answer
  answer=${answer:-Y}
  if [[ "$answer" =~ ^[Yy] ]]; then
    docker network create traefik-network || true
    start_traefik
  else
    err "Cannot continue without a reverse proxy."
    echo "If you have another proxy, create the 'traefik-network' Docker network,"
    echo "connect your proxy container to it, and re-run this script:"
    echo "  docker network create traefik-network"
    echo "  docker network connect traefik-network <your-proxy-container>"
    exit 1
  fi
}

start_traefik() {
  local traefik_dir="${INSTALL_DIR}/deploy/traefik"

  if [ ! -f "${traefik_dir}/docker-compose.traefik.yaml" ]; then
    err "Traefik files not found at ${traefik_dir}. Clone the repo first."
    exit 1
  fi

  # Set ACME email in traefik config
  read -rp "Email for Let's Encrypt certificates [admin@igk-digital.cloud]: " acme_email
  acme_email=${acme_email:-admin@igk-digital.cloud}

  # Add email to traefik.yaml
  sed -i "s|storage: /letsencrypt/acme.json|email: ${acme_email}\n      storage: /letsencrypt/acme.json|" "${traefik_dir}/traefik.yaml"

  info "Starting Traefik..."
  docker compose -f "${traefik_dir}/docker-compose.traefik.yaml" up -d

  # Wait for Traefik to be healthy
  local retries=0
  while [ $retries -lt 15 ]; do
    if docker inspect --format='{{.State.Health.Status}}' traefik 2>/dev/null | grep -q healthy; then
      log "Traefik is running and healthy"
      return 0
    fi
    sleep 2
    retries=$((retries + 1))
  done

  warn "Traefik started but healthcheck not yet passing. Continuing anyway..."
}

# ---------------------------------------------------------------------------
# 3. Clone repository
# ---------------------------------------------------------------------------
clone_repo() {
  info "Setting up ${INSTALL_DIR}..."

  if [ -d "${INSTALL_DIR}/.git" ]; then
    log "Repository already cloned. Pulling latest..."
    cd "${INSTALL_DIR}"
    git fetch origin "${REPO_BRANCH}"
    git checkout "${REPO_BRANCH}"
    git pull origin "${REPO_BRANCH}"
    cd -
  else
    mkdir -p "$(dirname "${INSTALL_DIR}")"
    git clone --branch "${REPO_BRANCH}" --depth 1 "${REPO_URL}" "${INSTALL_DIR}"
    log "Repository cloned to ${INSTALL_DIR}"
  fi

  # Verify critical files exist
  if [ ! -f "${INSTALL_DIR}/dynamicconfig/production-sql.yaml" ]; then
    err "dynamicconfig/production-sql.yaml not found in repo!"
    exit 1
  fi

  if [ ! -f "${COMPOSE_FILE}" ]; then
    err "deploy/docker-compose.prod.yaml not found in repo!"
    exit 1
  fi

  log "All required files present"
}

# ---------------------------------------------------------------------------
# 4. Configure environment
# ---------------------------------------------------------------------------
configure_env() {
  local env_file="${INSTALL_DIR}/deploy/.env"
  local template="${INSTALL_DIR}/deploy/.env.production.template"

  if [ -f "${env_file}" ]; then
    warn ".env file already exists at ${env_file}"
    read -rp "Overwrite it? [y/N]: " answer
    answer=${answer:-N}
    if [[ ! "$answer" =~ ^[Yy] ]]; then
      log "Keeping existing .env file"
      return 0
    fi
  fi

  info "Configuring environment..."
  cp "${template}" "${env_file}"

  # Domain (with validation)
  while true; do
    read -rp "Domain [postra.igk-digital.cloud]: " domain
    domain=${domain:-postra.igk-digital.cloud}

    # Reject obvious non-domain values (y, yes, n, no, single chars, etc.)
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]; then
      err "'${domain}' is not a valid domain name. Expected format: subdomain.example.com"
      continue
    fi

    # Must have at least one dot
    if [[ ! "$domain" == *.* ]]; then
      err "'${domain}' is not a valid domain name. Must contain at least one dot."
      continue
    fi

    break
  done

  # Generate secrets
  local jwt_secret
  jwt_secret=$(openssl rand -base64 48)
  local pg_password
  pg_password=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
  local temporal_pg_password
  temporal_pg_password=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)

  # Update .env with values
  sed -i "s|^DOMAIN=.*|DOMAIN=${domain}|" "${env_file}"
  sed -i "s|^MAIN_URL=.*|MAIN_URL=https://${domain}|" "${env_file}"
  sed -i "s|^FRONTEND_URL=.*|FRONTEND_URL=https://${domain}|" "${env_file}"
  sed -i "s|^NEXT_PUBLIC_BACKEND_URL=.*|NEXT_PUBLIC_BACKEND_URL=https://${domain}/api|" "${env_file}"
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${jwt_secret}|" "${env_file}"
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${pg_password}|" "${env_file}"
  sed -i "s|^TEMPORAL_POSTGRES_PASSWORD=.*|TEMPORAL_POSTGRES_PASSWORD=${temporal_pg_password}|" "${env_file}"

  # Certresolver (auto-detected or ask user)
  if [ -n "${DETECTED_CERTRESOLVER:-}" ]; then
    sed -i "s|^TRAEFIK_CERTRESOLVER=.*|TRAEFIK_CERTRESOLVER=${DETECTED_CERTRESOLVER}|" "${env_file}"
    log "Traefik certresolver set to '${DETECTED_CERTRESOLVER}' (auto-detected)"
  else
    read -rp "Traefik certresolver name [letsencrypt]: " certresolver
    certresolver=${certresolver:-letsencrypt}
    sed -i "s|^TRAEFIK_CERTRESOLVER=.*|TRAEFIK_CERTRESOLVER=${certresolver}|" "${env_file}"
    log "Traefik certresolver set to '${certresolver}'"
  fi

  log "Secrets generated and URLs configured for ${domain}"

  # Cloudflare R2
  echo ""
  info "Cloudflare R2 configuration (for media storage):"
  read -rp "  Cloudflare Account ID: " cf_account_id
  read -rp "  Cloudflare Access Key: " cf_access_key
  read -rp "  Cloudflare Secret Access Key: " cf_secret_key
  read -rp "  Cloudflare Bucket Name: " cf_bucket
  read -rp "  Cloudflare Bucket URL: " cf_bucket_url

  if [ -n "$cf_account_id" ]; then
    sed -i "s|^CLOUDFLARE_ACCOUNT_ID=.*|CLOUDFLARE_ACCOUNT_ID=${cf_account_id}|" "${env_file}"
    sed -i "s|^CLOUDFLARE_ACCESS_KEY=.*|CLOUDFLARE_ACCESS_KEY=${cf_access_key}|" "${env_file}"
    sed -i "s|^CLOUDFLARE_SECRET_ACCESS_KEY=.*|CLOUDFLARE_SECRET_ACCESS_KEY=${cf_secret_key}|" "${env_file}"
    sed -i "s|^CLOUDFLARE_BUCKETNAME=.*|CLOUDFLARE_BUCKETNAME=${cf_bucket}|" "${env_file}"
    sed -i "s|^CLOUDFLARE_BUCKET_URL=.*|CLOUDFLARE_BUCKET_URL=${cf_bucket_url}|" "${env_file}"
    log "Cloudflare R2 configured"
  else
    warn "Cloudflare R2 skipped. Media uploads will not work until configured."
  fi

  log "Environment configured at ${env_file}"
  echo ""
  info "You can edit social media API keys later in: ${env_file}"
}

# ---------------------------------------------------------------------------
# 5. Pull images
# ---------------------------------------------------------------------------
pull_images() {
  info "Pulling Docker images..."
  cd "${INSTALL_DIR}/deploy"

  # Check if GHCR image is accessible
  if ! docker pull ghcr.io/klevisgolemi/igk-post-app:latest 2>/dev/null; then
    warn "Cannot pull image. It may be private."
    echo ""
    echo "Option 1: Make the package public on GitHub"
    echo "  Go to: https://github.com/KlevisGolemi/igk-post-app/packages"
    echo "  Click the package → Settings → Change visibility → Public"
    echo ""
    echo "Option 2: Login to GHCR with a personal access token"
    read -rp "Login to GHCR now? [Y/n]: " answer
    answer=${answer:-Y}
    if [[ "$answer" =~ ^[Yy] ]]; then
      echo "Create a token at: https://github.com/settings/tokens/new"
      echo "Scope needed: read:packages"
      read -rp "GitHub username: " gh_user
      read -rsp "Personal access token: " gh_token
      echo ""
      echo "${gh_token}" | docker login ghcr.io -u "${gh_user}" --password-stdin
      docker pull ghcr.io/klevisgolemi/igk-post-app:latest
    else
      err "Cannot continue without the Docker image."
      exit 1
    fi
  fi

  # Pull remaining images
  docker compose -f docker-compose.prod.yaml pull
  log "All images pulled"
  cd -
}

# ---------------------------------------------------------------------------
# 6. Wait for healthcheck helper
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
        exit 1
        ;;
      not_found)
        # Container not yet created
        ;;
    esac

    sleep 3
    elapsed=$((elapsed + 3))
  done

  err "${container} did not become healthy within ${timeout}s. Showing logs:"
  docker logs "${container}" --tail 50
  exit 1
}

# ---------------------------------------------------------------------------
# 7. Start services (phased)
# ---------------------------------------------------------------------------
start_services() {
  cd "${INSTALL_DIR}/deploy"

  info "=== Phase 1: Starting databases ==="
  docker compose -f docker-compose.prod.yaml up -d postiz-postgres postiz-redis
  wait_healthy postiz-postgres 60
  wait_healthy postiz-redis 30

  info "=== Phase 2: Starting Temporal stack ==="
  docker compose -f docker-compose.prod.yaml up -d temporal-elasticsearch
  wait_healthy temporal-elasticsearch 90

  docker compose -f docker-compose.prod.yaml up -d temporal-postgresql
  wait_healthy temporal-postgresql 60

  docker compose -f docker-compose.prod.yaml up -d temporal
  wait_healthy temporal 120

  docker compose -f docker-compose.prod.yaml up -d temporal-admin-tools temporal-ui
  log "Temporal stack is running"

  info "=== Phase 3: Starting Postra application ==="
  docker compose -f docker-compose.prod.yaml up -d postiz
  wait_healthy postiz 180

  log "All services are running!"
  cd -
}

# ---------------------------------------------------------------------------
# 8. Verify deployment
# ---------------------------------------------------------------------------
verify() {
  local domain
  domain=$(grep '^DOMAIN=' "${INSTALL_DIR}/deploy/.env" | cut -d= -f2)

  info "Verifying deployment..."

  # Give it a moment for Traefik to pick up the new service
  sleep 5

  local http_code
  http_code=$(curl -so /dev/null -w "%{http_code}" --max-time 10 "https://${domain}" 2>/dev/null || echo "000")

  if [ "$http_code" = "200" ] || [ "$http_code" = "302" ] || [ "$http_code" = "307" ]; then
    log "HTTPS endpoint responding (HTTP ${http_code})"
  else
    warn "HTTPS returned HTTP ${http_code}. This may be normal if DNS is not yet pointing to this server."
    echo ""
    echo "Ensure your DNS has an A record:"
    echo "  ${domain} → $(curl -s ifconfig.me 2>/dev/null || echo '<your-server-ip>')"
  fi

  echo ""
  echo "=========================================="
  echo -e "${GREEN} Postra deployment complete!${NC}"
  echo "=========================================="
  echo ""
  echo "  App URL:         https://${domain}"
  echo "  Temporal UI:     http://127.0.0.1:8080 (SSH tunnel required)"
  echo "    ssh -L 8080:127.0.0.1:8080 user@your-server"
  echo ""
  echo "  Env file:        ${INSTALL_DIR}/deploy/.env"
  echo "  Compose file:    ${INSTALL_DIR}/deploy/docker-compose.prod.yaml"
  echo "  Logs:            docker compose -f ${COMPOSE_FILE} logs -f postiz"
  echo "  Update:          bash ${INSTALL_DIR}/deploy/update.sh"
  echo ""
  echo "  First steps:"
  echo "    1. Open https://${domain} and create your account"
  echo "    2. Add social media API keys in ${INSTALL_DIR}/deploy/.env"
  echo "    3. Restart after adding keys: docker compose -f ${COMPOSE_FILE} up -d --no-deps postiz"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  echo "=========================================="
  echo "  Postra - Production Deployment"
  echo "=========================================="
  echo ""

  preflight
  clone_repo
  setup_traefik
  configure_env
  pull_images
  start_services
  verify
}

main "$@"
