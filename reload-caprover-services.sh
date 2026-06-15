#!/bin/bash

# Stop only selected caprover app services except core services
echo "Stopping services..."
docker service ls --format '{{.Name}} {{.Replicas}}' | grep '^srv-captain--' | \
    grep -v '0/0' | \
    awk '{print $1}' | \
    while read s; do
        docker service scale ${s}=0
        echo "Stopped ${s}"
    done

# Stop caprover core services
echo "Stopping core services..."
for s in captain-captain captain-certbot captain-nginx captain-registry; do
    docker service scale ${s}=0
    echo "Stopped ${s}"
done

# Clear cache and memory
echo "Clearing cache and memory..."
sudo swapoff -a && sudo swapon -a
sudo sh -c 'sync && echo 3 > /proc/sys/vm/drop_caches'

# Clean Docker resources
echo "Cleaning Docker resources..."
docker system prune -f
find /var/lib/docker/containers/ -name "*.log" -exec truncate -s 0 {} \;

# Clean system logs and temp files
echo "Cleaning system logs and temp files..."
sudo journalctl --vacuum-size=100M
sudo rm -rf /tmp/*

# Restart docker
echo "Restarting docker..."
sudo systemctl restart docker
sleep 5

# Start caprover core services (captain services)
echo "Starting core services..."
for s in captain-captain captain-certbot captain-nginx captain-registry; do
    docker service scale ${s}=1
    echo "Started ${s}"
done

# Start project services
echo "Starting project database services..."
for s in \
  srv-captain--mariadb-db \
  srv-captain--phpmyadmin \
  srv-captain--pgsql \
  srv-captain--pg-admin \
  srv-captain--minio-s3 \
  srv-captain--minio-s3-api \
  srv-captain--rustfs \
  srv-captain--rustfs-api; do
    docker service scale ${s}=1
    echo "Started ${s}"
done