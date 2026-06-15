# caprover-reloader

Shell script to restart CapRover services in an ordered sequence, clear caches, restart Docker, and then bring selected services back online.

## Files

- `reload-caprover-services.sh`: main automation script

## Make Script Executable

In this repository:

```bash
chmod +x reload-caprover-services.sh
```

## Run Locally

```bash
./reload-caprover-services.sh
```

> Note: This script uses `docker`, `sudo`, and `systemctl`, and is intended for Linux servers with Docker Swarm/CapRover.

## Download and Run on a Server with curl

Yes, you can use `curl`.

### Option 1: Download then run

```bash
curl -fsSL https://raw.githubusercontent.com/AlmossaidLLC/caprover-reloader/main/reload-caprover-services.sh -o reload-caprover-services.sh
chmod +x reload-caprover-services.sh
./reload-caprover-services.sh
```

### Option 2: Run directly with bash (without saving)

```bash
curl -fsSL https://raw.githubusercontent.com/AlmossaidLLC/caprover-reloader/main/reload-caprover-services.sh | bash
```

Use Option 2 only if you trust the source and understand the script.

## Push This Project to GitHub

Repository:

```text
git@github.com:AlmossaidLLC/caprover-reloader.git
```

Commands:

```bash
git init
git branch -M main
git remote add origin git@github.com:AlmossaidLLC/caprover-reloader.git
chmod +x reload-caprover-services.sh
git add reload-caprover-services.sh README.md
git commit -m "Add CapRover reload script and README"
git push -u origin main
```
