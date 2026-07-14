#!/bin/bash

# Start order matters: captain first, then registry, nginx, certbot.
# Stop uses the reverse order.
CORE_SERVICES=(
  captain-captain
  captain-registry
  captain-nginx
  captain-certbot
)
DB_SERVICES=(
  srv-captain--mariadb-db
  srv-captain--pgsql
  srv-captain--redis
  srv-captain--dbgate
#   srv-captain--phpmyadmin
#   srv-captain--pg-admin
  srv-captain--minio-s3
  srv-captain--minio-s3-api
  srv-captain--rustfs
  srv-captain--rustfs-api
)

is_core_service() {
    local n="$1"
    local c
    for c in "${CORE_SERVICES[@]}"; do
        [ "$c" = "$n" ] && return 0
    done
    return 1
}

# Wait until Docker/Swarm responds after restart
wait_for_docker() {
    local i=0
    until docker info >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge 60 ]; then
            echo "Docker did not become ready in time" >&2
            return 1
        fi
        sleep 1
    done
}

# Docker requires bind mount source paths to exist before tasks can start
ensure_service_bind_paths() {
    local s="$1"
    local src
    while IFS= read -r src; do
        [ -n "$src" ] || continue
        if [ ! -e "$src" ]; then
            echo "Creating missing bind path for ${s}: ${src}"
            mkdir -p "$src"
        fi
    done < <(docker service inspect "$s" --format '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Type "bind"}}{{println .Source}}{{end}}{{end}}')
}

# Wait until a service reports 1/1 (or timeout)
wait_for_service_1() {
    local s="$1"
    local timeout="${2:-90}"
    local i=0
    local replicas
    echo "Waiting for ${s} to become 1/1..."
    while [ "$i" -lt "$timeout" ]; do
        replicas="$(docker service ls --format '{{.Name}} {{.Replicas}}' | awk -v n="$s" '$1 == n {print $2}')"
        case "$replicas" in
            1/1*) return 0 ;;
        esac
        i=$((i + 1))
        sleep 1
    done
    echo "Warning: ${s} did not reach 1/1 within ${timeout}s (last: ${replicas:-unknown})" >&2
    return 1
}

# Force-recreate a core service at 1 replica (more reliable than scale alone)
start_core_service() {
    local s="$1"
    if [ -z "${EXISTING_SERVICES[$s]:-}" ]; then
        echo "Skipping ${s} (not found)"
        return 0
    fi
    ensure_service_bind_paths "$s"
    if ! docker service update --replicas 1 --force "$s"; then
        echo "Retrying ${s} after re-checking bind paths..."
        ensure_service_bind_paths "$s"
        docker service update --replicas 1 --force "$s" || {
            echo "Failed to start ${s}" >&2
            return 1
        }
    fi
    echo "Started ${s} (force update)"
}

# One pass: collect existing names, multi-replica services, and apps to stop
declare -A EXISTING_SERVICES=()
SCALED_SERVICES=()
STOP_SCALE_ARGS=()

echo "Collecting services..."
while read -r name replicas; do
    EXISTING_SERVICES["$name"]=1

    if is_core_service "$name"; then
        continue
    fi

    desired="${replicas%%/*}"
    if [ -n "$desired" ] && [ "$desired" -gt 1 ] 2>/dev/null; then
        SCALED_SERVICES+=("$name")
        echo "Found ${name} with ${desired} replicas (will restore to 1)"
    fi

    case "$name" in
        srv-captain--*)
            if [ "$replicas" != "0/0" ]; then
                STOP_SCALE_ARGS+=("${name}=0")
            fi
            ;;
    esac
done < <(docker service ls --format '{{.Name}} {{.Replicas}}')

# Stop app services in one batch (frees CPU fastest under load)
echo "Stopping app services..."
if [ ${#STOP_SCALE_ARGS[@]} -gt 0 ]; then
    docker service scale "${STOP_SCALE_ARGS[@]}"
    echo "Stopped ${#STOP_SCALE_ARGS[@]} app services"
fi

# Stop CapRover core in reverse order (certbot → nginx → registry → captain)
echo "Stopping core services..."
CORE_STOP_ARGS=()
for ((i=${#CORE_SERVICES[@]}-1; i>=0; i--)); do
    CORE_STOP_ARGS+=("${CORE_SERVICES[i]}=0")
done
docker service scale "${CORE_STOP_ARGS[@]}"
echo "Stopped core services"

# Light memory reclaim (CPU should be freer now)
echo "Clearing cache and memory..."
sudo swapoff -a && sudo swapon -a
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'

# Heavier cleanup only after services are down
echo "Cleaning Docker resources..."
docker system prune -f
find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \;

echo "Cleaning system logs and temp files..."
sudo journalctl --vacuum-size=100M
sudo rm -rf /tmp/*

# Restart docker and wait until it is actually ready
echo "Restarting docker..."
sudo systemctl restart docker
wait_for_docker

# Ensure CapRover root data dir exists after docker restart
mkdir -p /captain/data

# Start CapRover core in dependency order with force recreate.
# Wait for captain-captain first — it owns shared paths that registry/nginx need.
echo "Starting core services..."
for s in "${CORE_SERVICES[@]}"; do
    start_core_service "$s" || true
    if [ "$s" = "captain-captain" ]; then
        wait_for_service_1 "captain-captain" 90 || true
    fi
done

# Start only DB/project services that actually exist (skip missing to avoid slow failures)
echo "Starting project database services..."
DB_START_ARGS=()
for s in "${DB_SERVICES[@]}"; do
    if [ -n "${EXISTING_SERVICES[$s]:-}" ]; then
        DB_START_ARGS+=("${s}=1")
    else
        echo "Skipping ${s} (not found)"
    fi
done
if [ ${#DB_START_ARGS[@]} -gt 0 ]; then
    docker service scale "${DB_START_ARGS[@]}"
    echo "Started ${#DB_START_ARGS[@]} project services"
else
    echo "No project services found to start"
fi

# Restore collected multi-replica services strictly to 1 (batch)
if [ ${#SCALED_SERVICES[@]} -gt 0 ]; then
    echo "Restoring multi-replica services to 1..."
    RESTORE_ARGS=()
    for s in "${SCALED_SERVICES[@]}"; do
        RESTORE_ARGS+=("${s}=1")
    done
    docker service scale "${RESTORE_ARGS[@]}"
    echo "Scaled ${#SCALED_SERVICES[@]} services to 1"
fi
