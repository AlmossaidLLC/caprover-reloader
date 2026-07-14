#!/bin/bash

CORE_SERVICES="captain-captain captain-certbot captain-nginx captain-registry"
DB_SERVICES=(
  srv-captain--mariadb-db
  srv-captain--phpmyadmin
  srv-captain--pgsql
  srv-captain--pg-admin
  srv-captain--minio-s3
  srv-captain--minio-s3-api
  srv-captain--rustfs
  srv-captain--rustfs-api
)

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

# One pass: collect existing names, multi-replica services, and apps to stop
declare -A EXISTING_SERVICES=()
SCALED_SERVICES=()
STOP_SCALE_ARGS=()

echo "Collecting services..."
while read -r name replicas; do
    EXISTING_SERVICES["$name"]=1

    case " $CORE_SERVICES " in
        *" $name "*) continue ;;
    esac

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

# Stop CapRover core in one batch
echo "Stopping core services..."
CORE_STOP_ARGS=()
for s in $CORE_SERVICES; do
    CORE_STOP_ARGS+=("${s}=0")
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

# Start CapRover core in one batch
echo "Starting core services..."
CORE_START_ARGS=()
for s in $CORE_SERVICES; do
    CORE_START_ARGS+=("${s}=1")
done
docker service scale "${CORE_START_ARGS[@]}"
echo "Started core services"

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
