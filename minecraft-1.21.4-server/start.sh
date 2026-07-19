#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT}"

MIN_RAM="${MIN_RAM:-1G}"
MAX_RAM="${MAX_RAM:-2G}"

if [[ ! -f server.jar ]]; then
  echo "server.jar missing. Run ./setup.sh first."
  exit 1
fi

if ! grep -qiE '^[[:space:]]*eula[[:space:]]*=[[:space:]]*true[[:space:]]*$' eula.txt; then
  echo "EULA not accepted. Edit eula.txt and set eula=true after reading https://aka.ms/MinecraftEULA"
  exit 1
fi

if ! command -v java >/dev/null 2>&1; then
  echo "Java not found. Minecraft 1.21.4 requires Java 21+."
  exit 1
fi

echo "Starting Minecraft 1.21.4 ( -Xms${MIN_RAM} -Xmx${MAX_RAM} )..."
exec java -Xms"${MIN_RAM}" -Xmx"${MAX_RAM}" -jar server.jar nogui
