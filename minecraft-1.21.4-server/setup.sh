#!/usr/bin/env bash
set -euo pipefail

VERSION="1.21.4"
EXPECTED_SHA1="4707d00eb834b446575d89a61a11b5d548d8c001"
SERVER_JAR_URL="https://piston-data.mojang.com/v1/objects/${EXPECTED_SHA1}/server.jar"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAR_PATH="${ROOT}/server.jar"

cd "${ROOT}"

if [[ -f "${JAR_PATH}" ]]; then
  CURRENT_SHA1="$(sha1sum "${JAR_PATH}" | awk '{print $1}')"
  if [[ "${CURRENT_SHA1}" == "${EXPECTED_SHA1}" ]]; then
    echo "server.jar already present and verified (${VERSION})."
    exit 0
  fi
  echo "Existing server.jar checksum mismatch; re-downloading..."
  rm -f "${JAR_PATH}"
fi

echo "Downloading Minecraft ${VERSION} server.jar..."
curl -fsSL "${SERVER_JAR_URL}" -o "${JAR_PATH}"

ACTUAL_SHA1="$(sha1sum "${JAR_PATH}" | awk '{print $1}')"
if [[ "${ACTUAL_SHA1}" != "${EXPECTED_SHA1}" ]]; then
  echo "Checksum verification failed."
  echo "  expected: ${EXPECTED_SHA1}"
  echo "  actual:   ${ACTUAL_SHA1}"
  rm -f "${JAR_PATH}"
  exit 1
fi

echo "Downloaded and verified Minecraft ${VERSION} server.jar"
echo "Next: accept the EULA in eula.txt (set eula=true), then run ./start.sh"
