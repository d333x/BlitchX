# Minecraft 1.21.4 Server

Vanilla Java Edition server for **Minecraft 1.21.4** (requires **Java 21+**).

Maps to a local install folder such as `D:\minecraft-1.21.4-server`.

## Quick start (Windows)

```powershell
cd minecraft-1.21.4-server
.\setup.ps1
# Edit eula.txt → set eula=true after reading https://aka.ms/MinecraftEULA
.\start.ps1
```

Optional memory:

```powershell
$env:MIN_RAM = "2G"
$env:MAX_RAM = "4G"
.\start.ps1
```

## Quick start (Linux / macOS)

```bash
cd minecraft-1.21.4-server
chmod +x setup.sh start.sh
./setup.sh
# Edit eula.txt → set eula=true after reading https://aka.ms/MinecraftEULA
./start.sh
```

Optional memory:

```bash
MIN_RAM=2G MAX_RAM=4G ./start.sh
```

## Files

| File | Purpose |
|------|---------|
| `setup.ps1` / `setup.sh` | Download + SHA-1 verify official `server.jar` |
| `start.ps1` / `start.sh` | Launch the server (`nogui`) |
| `server.properties` | Port, MOTD, gamemode, difficulty, view distance, etc. |
| `eula.txt` | Mojang EULA acceptance (`eula=false` until you agree) |

Default game port: **25565**.

## Notes

- `server.jar` is not committed; run the setup script to fetch it from Mojang.
- World folders, logs, and player lists are gitignored.
- Set `online-mode=false` in `server.properties` only for offline/LAN testing (not recommended for public servers).
