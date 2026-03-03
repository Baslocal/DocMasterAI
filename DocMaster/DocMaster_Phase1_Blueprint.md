# DocMaster — Phase 1 Blueprint
## OS Foundation & Environment Hardening

**Classification:** Confidential — Internal Engineering Reference  
**Phase:** 1 of 8  
**Complexity:** Easy  
**Prerequisite:** None — this is the foundation everything else builds on  
**Outcome:** A hardened, minimal Linux environment with the correct user, directory structure, pinned dependencies, and service user permissions — ready to receive application code in Phase 2

---

## Overview

Phase 1 is the bedrock of the entire DocMaster appliance. Nothing from Phase 2 onward can be reliably built without this phase being complete, verified, and locked down. The goal is not to install DocMaster — it is to prepare the operating system so that DocMaster can be installed correctly and consistently every time.

This phase covers five distinct tracks that must be completed in order:

1. Base OS provisioning and hardening  
2. Service user and group creation  
3. Directory structure and permissions  
4. Dependency installation and version pinning  
5. GPU / NVIDIA setup (conditional — hardware dependent)

Each track has its own checklist and design rationale. Every decision made here has downstream consequences, so no step should be skipped or approximated.

---

## Design Decisions & Rationale

Before touching any system, the following architectural decisions must be locked in. These are not implementation choices — they are design constraints that Phase 1 enforces permanently.

### Operating System

**Decision:** Debian 12 (Bookworm) or Ubuntu Server 24.04 LTS — minimal install, no desktop environment.

**Rationale:** Both distributions offer long-term support, predictable package lifecycles, and a well-understood systemd implementation. The minimal install discipline matters because every unnecessary package is a potential vulnerability and a maintenance burden. Debian is preferred for air-gapped deployments because its package ecosystem is more conservative and stable. Ubuntu 24.04 LTS is acceptable where customers have existing Ubuntu familiarity or where hardware support requires a newer kernel.

**What to avoid:** Do not use Debian Testing, Ubuntu non-LTS, CentOS, or any rolling-release distribution. Do not install a GUI layer at any point — the appliance is administered entirely through the web UI and optionally SSH.

### System User Architecture

**Decision:** All DocMaster application processes run under a single dedicated system user: `docmaster`. This user has no login shell, no home directory, and no sudo privileges.

**Rationale:** The principle of least privilege. If any DocMaster process is compromised, the blast radius is limited to what `docmaster` can access — which is only `/opt/docmaster/`. No process should ever run as root. No process should ever be able to write outside its designated directories.

**The `docgroup` group** is created separately so that future roles (e.g., a read-only audit user) can be given scoped access to specific log directories without being granted full `docmaster` permissions.

### Directory Isolation

**Decision:** All DocMaster files live exclusively under `/opt/docmaster/`. Nothing is scattered across `/etc/`, `/var/`, `/home/`, or other standard system locations.

**Rationale:** This isolation makes the appliance easy to backup, easy to remove, and easy to audit. It also makes the Blue/Green update mechanism possible — the entire application can be swapped by updating a symlink to `/opt/docmaster/`. Any config that must interact with the OS (e.g., systemd service files) lives at OS-level paths as a deliberate, documented exception.

### Dependency Pinning Philosophy

**Decision:** Every installed package, Python library, and binary is pinned to an exact version. The manifest is written to `/opt/docmaster/vault/manifest.lock` before the phase is considered complete.

**Rationale:** This is what prevents the appliance from breaking when an upstream package increments a version. Customer appliances must be identical to the build that was tested. Upstream registries are not trusted for production reads — they are only used by the internal build pipeline, which then vendors the outputs. On the customer machine, all packages come from the installer, not from the internet.

---

## Track 1 — Base OS Provisioning

### 1.1 Installation Parameters

The OS installation must be performed with the following parameters. These are not preferences — they are requirements.

**Partition Layout:**

The disk should be partitioned with a dedicated layout that separates the OS from the application data. This matters because a full application data partition should never cause the OS to become unresponsive, and a full OS partition should never corrupt application data.

- `/` (root): 40 GB minimum — holds OS binaries, systemd, and package manager state
- `/opt` (or a dedicated partition): 200 GB minimum — holds the entire DocMaster installation, models, and temporary processing space. If the deployment target is a high-volume environment, this should be sized to 500 GB or more. The models directory alone can consume 20–40 GB depending on the configuration.
- `/var/log`: 10 GB minimum — separated to prevent log bloat from filling root
- `swap`: Equal to RAM, up to 32 GB — required if the deployment will run LLM inference on a memory-constrained machine

**Filesystem:** `ext4` for all partitions. Do not use `btrfs` or `zfs` unless there is a specific hardware RAID requirement — they add complexity that the appliance is not designed to manage.

**Boot:** Use GRUB2. UEFI boot is preferred where hardware supports it.

**Locale and Encoding:** Set system locale to `en_US.UTF-8`. This is critical for consistent OCR output encoding. Mismatched locale settings have caused subtle extraction failures in multilingual pipelines.

**Timezone:** Set to UTC during installation. Every timestamp in every log, database record, and license file will be in UTC. This is non-negotiable — local timezone settings create ambiguous timestamps that break audit trails and make cross-site comparisons impossible.

### 1.2 Post-Install Hardening Steps

These steps must be performed immediately after the first boot, before any application software is installed.

**Disable Unnecessary Services:**

The following services should be disabled and masked if present. They serve no purpose in a headless appliance and represent unnecessary attack surface and background resource consumption.

- `avahi-daemon` — mDNS/DNS-SD; not needed (the appliance uses static hostname resolution)
- `cups` and `cups-browsed` — printing subsystem; irrelevant
- `bluetooth` — not applicable to server hardware
- `ModemManager` — interferes with fax modem if not properly excluded
- `snapd` — introduces unpredictable update behavior; conflicts with the pinning strategy
- `unattended-upgrades` — must be reconfigured specifically for security patches only (see below)

The correct approach is to both disable and mask the services rather than just disabling them. Masking prevents them from being accidentally started as a dependency of another service. Simply disabling them without masking leaves a gap.

**Network Configuration:**

Assign a static IP address. The appliance must have a predictable address on the local network — DHCP introduces a failure point where a lease expiry or DHCP server restart makes the appliance unreachable. Document the assigned IP in the deployment record.

Set the hostname to `docmaster-node-01` (or `docmaster-node-02` etc. for multi-unit deployments). The hostname is used in the license fingerprint calculation and in the health check node identifier — it should not change after provisioning.

Configure `/etc/hosts` to include an entry for the appliance's own hostname resolving to its static IP. This prevents certain services from failing to resolve their own identity when DNS is unavailable.

**SSH Hardening:**

SSH is the only remote administrative access mechanism. It must be locked down before the appliance is considered production-ready.

- Generate an RSA-4096 or Ed25519 key pair for the admin user
- Copy the public key to `~/.ssh/authorized_keys` on the target machine
- Edit `/etc/ssh/sshd_config` to:
  - Set `PasswordAuthentication no`
  - Set `PermitRootLogin no`
  - Set `AllowUsers` to only the designated admin username
  - Set `Port` to a non-default value if the deployment environment requires it (document the port)
  - Set `MaxAuthTries 3`
  - Set `LoginGraceTime 30`
- Restart SSH and verify key-based login works before closing the current session — this is a lockout risk if done incorrectly

**Firewall Configuration (UFW):**

The firewall rules define exactly what is accessible from the network. The default policy must be `deny all inbound`, with explicit allow rules for only what is needed.

Required allow rules:
- SSH on the configured port (from admin IP range only, if the deployment environment supports IP-based rules)
- DocMaster UI/API on port `8080` (from local network range only)
- ICMP (ping) — optional but recommended for network diagnostics

Explicitly blocked or not opened:
- Port 5432 (PostgreSQL) — local only, never exposed
- Port 6379 (Redis) — local only, never exposed
- Port 11434 (Ollama) — local only, never exposed
- Port 445 (Samba) — should be scoped to local network range only if SMB scan drop is enabled
- All other ports

**NTP Configuration:**

Install and configure `chrony` for time synchronization. Accurate system time is required for two critical reasons: license fingerprint validation relies on consistent timestamp generation, and JWT signatures in the license system use `issued_at` and `expires_at` fields that must reflect real clock time.

Configure `chrony` to use reliable NTP servers. In air-gapped deployments where the appliance has no internet access, the NTP source must be a local network NTP server. This must be confirmed with the customer before deployment — if there is no local NTP and no internet access, the appliance clock will drift and eventually cause license validation failures.

**Automatic Security Patches:**

The appliance should receive OS-level security patches automatically, but only security patches — not general package upgrades. General upgrades could increment a pinned dependency and break the pipeline. Configure `unattended-upgrades` to apply `${distro_id}:${distro_codename}-security` updates only, with automatic reboot disabled. A reboot after a security patch must be a deliberate action by the administrator.

---

## Track 2 — Service User & Group

### 2.1 User and Group Design

The `docmaster` system user is the identity under which all DocMaster application processes execute. It is not a human user — it cannot log in interactively and has no home directory.

**User attributes:**
- Username: `docmaster`
- UID: Let the system assign — do not hardcode a UID unless the deployment has a specific requirement (e.g., shared NFS storage that requires consistent UIDs across nodes)
- Shell: `/bin/false` or `/usr/sbin/nologin` — prevents interactive login even if a password were somehow set
- Home directory: none (use `/opt/docmaster` as the working directory for services, specified in each systemd unit file)
- Password: none — locked account

**Group attributes:**
- Group name: `docgroup`
- The `docmaster` user is the primary member
- No other OS users should be in `docgroup` unless there is a specific documented reason

**Why a separate group?**  
Future audit or monitoring roles can be granted read-only access to specific subdirectories (e.g., `/opt/docmaster/logs/`) by being added to `docgroup` without being given full `docmaster` user permissions. This also allows the Samba scan share to run under a separate `scanuser` that has write access only to `/opt/docmaster/ingest/` — configured via group permissions rather than by expanding `docmaster`'s access.

### 2.2 Admin User

A separate admin user must be created for SSH access and system administration. This user should not be `root` and should have `sudo` access limited to specific commands necessary for system management (e.g., `systemctl`, `journalctl`, package management).

The admin user is separate from the `docmaster` service user. The admin user never owns DocMaster files — file ownership belongs exclusively to `docmaster:docgroup`.

---

## Track 3 — Directory Structure & Permissions

### 3.1 Full Directory Tree

The following directory tree must be created exactly as specified. The names are not arbitrary — they correspond to service names, API namespaces, and log references throughout the codebase.

```
/opt/docmaster/
├── bin/
├── core/
├── flux/
├── mind/
├── bridge/
├── sentinel/
├── vault/
├── models/
├── ingest/
├── tmp/
├── data/
├── queue/
├── logs/
└── backups/
```

**Purpose of each directory:**

| Directory | Purpose | Notes |
|-----------|---------|-------|
| `bin/` | Compiled binaries and shell management scripts | All executables that the systemd services call live here |
| `core/` | FastAPI application source tree | The main API server codebase |
| `flux/` | Ingest pipeline worker source | File watcher daemon and queue consumer |
| `mind/` | Ollama wrapper source and model configuration | LLM inference interface layer |
| `bridge/` | External connector adapter source | Google Drive, email, fax, SFTP connectors |
| `sentinel/` | Health monitor daemon source | Watchdog, diagnostic runner, alert handler |
| `vault/` | License engine, encrypted config, manifest | Most sensitive directory — tightest permissions |
| `models/` | Pinned OCR and LLM model files | Can be large (20–40 GB); should be on the largest partition |
| `ingest/` | Live document drop folder | Watched by `dm-flux`; files land here and are immediately moved |
| `tmp/` | Ephemeral per-job processing workspace | Cleared by cron; never persisted across reboots |
| `data/` | PostgreSQL data directory | Managed by PostgreSQL — do not manually modify |
| `queue/` | Redis RDB persistence files | Managed by Redis — do not manually modify |
| `logs/` | Centralized structured log output | All services write here; cron rotates and archives |
| `backups/` | Encrypted nightly DB dumps and log archives | Should ideally be on a separate disk or mount |

### 3.2 Permission Matrix

Permissions must be applied after the directory tree is created. The following table defines the ownership and mode for each directory:

| Directory | Owner | Group | Mode | Rationale |
|-----------|-------|-------|------|-----------|
| `/opt/docmaster/` | `docmaster` | `docgroup` | `750` | Root directory — group read for audit access |
| `bin/` | `docmaster` | `docgroup` | `750` | Executables — owner execute only |
| `core/` | `docmaster` | `docgroup` | `750` | Application source — no external read |
| `flux/` | `docmaster` | `docgroup` | `750` | Same as core |
| `mind/` | `docmaster` | `docgroup` | `750` | Same as core |
| `bridge/` | `docmaster` | `docgroup` | `750` | Same as core |
| `sentinel/` | `docmaster` | `docgroup` | `750` | Same as core |
| `vault/` | `docmaster` | `docgroup` | `700` | Most sensitive — owner only, no group read |
| `models/` | `docmaster` | `docgroup` | `750` | Large model files — group read acceptable |
| `ingest/` | `docmaster` | `docgroup` | `770` | Write access needed for scan drop (Samba uses docgroup) |
| `tmp/` | `docmaster` | `docgroup` | `700` | Processing workspace — owner only |
| `data/` | `docmaster` | `docgroup` | `700` | PostgreSQL data — strict owner-only |
| `queue/` | `docmaster` | `docgroup` | `700` | Redis persistence — strict owner-only |
| `logs/` | `docmaster` | `docgroup` | `750` | Group read allows admin to tail logs without sudo |
| `backups/` | `docmaster` | `docgroup` | `700` | Encrypted archives — owner only |

**File-level permissions within directories:**

- Configuration files in `vault/`: `640` (owner read/write, group read — but `vault/` itself is `700`, so group cannot traverse into it anyway)
- Executable scripts in `bin/`: `750`
- Log files in `logs/`: `640`
- Model files in `models/`: `640`

**Critical rule:** The permissions must be applied recursively on initial creation and must be revalidated by the Phase 5 sentinel health check on every boot. Any file or directory with permissions wider than specified above should be flagged as a misconfiguration.

### 3.3 The /opt/docmaster Symlink Architecture

The live directory is actually a symlink:

```
/opt/docmaster-blue/    ← live installation (active)
/opt/docmaster-green/   ← staged update (standby)
/opt/docmaster          ← symlink → /opt/docmaster-blue/
```

During Phase 1, only `/opt/docmaster-blue/` is created. The symlink `/opt/docmaster` points to it. All systemd service files, cron jobs, and application configs reference `/opt/docmaster/` — never the `-blue` or `-green` path directly. This is what makes the Phase 5 Blue/Green update atomic.

**Phase 1 task:** Create `/opt/docmaster-blue/` with the full directory tree, then create the symlink `/opt/docmaster → /opt/docmaster-blue/`. All subsequent Phase 1 work is performed through the symlink path.

---

## Track 4 — Dependency Installation

### 4.1 Installation Philosophy

All dependencies are installed from the distribution's official package repositories or from official upstream binary releases pinned to a specific version. After installation, every package version is recorded in the manifest file. On the customer appliance, packages are never updated outside of a formal DocMaster update package.

The installation order matters. Some packages have interdependencies that will fail silently if installed out of sequence. The order below is tested and should be followed exactly.

### 4.2 System Package Dependencies

**Core system tools (install first):**

These are utilities needed to complete the rest of the installation. Without them, subsequent installation steps will fail.

- `curl` — downloading binaries and making health check calls
- `wget` — alternative download utility for some package sources
- `git` — version control for any source-based installations
- `gnupg` — required for verifying package signing keys
- `apt-transport-https` — required for HTTPS package sources
- `ca-certificates` — TLS certificate validation
- `software-properties-common` — for managing additional apt repositories
- `build-essential` — compiler toolchain needed for some Python package builds
- `jq` — JSON parsing in shell scripts
- `rsync` — file synchronization for backup scripts
- `htop` — process monitoring
- `lsof` — open file inspection (critical for debugging stuck jobs)
- `unzip` — archive extraction

**Database layer:**

PostgreSQL must be installed from the official PostgreSQL Global Development Group (PGDG) apt repository, not from the distribution's default repository. The distribution repository often ships an older version. DocMaster requires PostgreSQL 16.

- Add the PGDG apt signing key and repository before installing
- Install: `postgresql-16`, `postgresql-client-16`, `postgresql-16-pgvector`
- The `pgvector` extension is required for semantic search — it must be installed as part of this phase, not added later
- Do not start the PostgreSQL service yet — data directory initialization happens in Phase 2

**Queue layer:**

Redis must be installed from the official Redis apt repository, not from the distribution default. The distribution default may ship Redis 6, which lacks features used in the queue design.

- Add the Redis official apt repository before installing
- Install: `redis-server` (version 7.x)
- Do not start the Redis service yet — configuration happens in Phase 2

**Python runtime:**

- Install `python3.12`, `python3.12-venv`, `python3.12-dev`, `python3-pip`
- Python 3.12 is the minimum required version — earlier versions lack performance improvements used in the OCR worker
- Do not use the system Python for DocMaster's virtual environment — create a dedicated venv under `/opt/docmaster/core/.venv/` in Phase 2

**Node.js runtime:**

- Install Node.js 22 LTS from the NodeSource official repository
- Install `npm` alongside Node.js
- Node.js is used for the React UI build pipeline and any JS-based tooling
- Do not use the distribution's default Node.js package — it is typically multiple major versions behind

**OCR engine — Tesseract:**

- Install `tesseract-ocr` version 5.x
- Install all relevant language packs: at minimum `tesseract-ocr-eng` (English). For deployments in specific regions, install the appropriate language data packages. Document which language packs are installed in the manifest.
- Install `tesseract-ocr-script-latn` for Latin-script document support
- Tesseract 5 uses the LSTM neural network engine by default — this is required, not optional

**PDF and image handling:**

- `poppler-utils` — provides `pdfinfo`, `pdftoppm`, `pdfimages` for PDF inspection and rasterization
- `imagemagick` — image conversion and manipulation
- `ghostscript` — PostScript and PDF processing (dependency of some OCR pre-processing steps)
- `libsm6`, `libxext6`, `libgl1-mesa-glx`, `libglib2.0-0` — OpenCV runtime dependencies
- `ffmpeg` — media handling for any video or audio-based document types

**Mail handling:**

- `postfix` — install in `Local only` mode during package configuration. This means Postfix will only accept mail addressed to the local machine — it will not relay mail externally. The configuration will be refined in Phase 4 (Multi-Channel Ingest), but the package must be installed here.
- `mailutils` — command-line mail utilities for testing the Postfix installation

**File sharing (SMB scan drop):**

- `samba` — provides the SMB server for the network scan drop folder
- `samba-common-bin` — Samba configuration utilities
- Samba configuration (shares, users, auth) is done in Phase 4, but the package must be installed in Phase 1

**Fax handling:**

- `hylafax-server` — fax server daemon. Requires a USB fax modem connected to the server for operational use, but the package should be installed regardless so the Phase 4 configuration is not blocked by a missing package
- If the deployment environment uses ICTFax instead, install its dependencies at this stage — the choice between HylaFAX and ICTFax must be made before Phase 1 completes, as they have different dependency trees

**System utilities:**

- `chrony` — NTP time synchronization (configured in Track 1)
- `ufw` — firewall management (configured in Track 1)
- `acl` — filesystem ACL support, needed for fine-grained permission management
- `logrotate` — log rotation (cron-based rotation is defined in Phase 5, but the tool must be present)
- `cron` — job scheduler (verify it is installed and enabled)

### 4.3 Ollama Installation

Ollama is not installed from the system package manager. It is installed as a pinned binary directly into `/opt/docmaster/bin/`.

**Why not the system-wide install?**  
The standard Ollama install script (`curl -fsSL https://ollama.com/install.sh | sh`) installs to `/usr/local/bin/` and creates a system-wide service. This conflicts with the DocMaster isolation model. DocMaster needs full control over the Ollama binary version, service configuration, environment variables, and data directory. Installing system-wide creates version drift risk and makes future pinned updates harder.

**Install procedure:**

- Download the Ollama binary from the official Ollama release on GitHub at the exact pinned version specified in the build manifest
- Place the binary at `/opt/docmaster/bin/ollama`
- Set ownership `docmaster:docgroup` and mode `750`

**Environment configuration:**

The following environment variables must be set for the `docmaster` user and for the `dm-mind.service` systemd unit:

- `OLLAMA_MODELS=/opt/docmaster/models` — stores all model files inside the DocMaster directory tree, not in a default system location
- `OLLAMA_HOST=127.0.0.1:11434` — binds Ollama to localhost only, preventing any external network access to the inference API
- `OLLAMA_KEEP_ALIVE=5m` — keeps the model loaded in memory for 5 minutes between requests. Adjust based on deployment RAM. Lower values save memory; higher values reduce inference latency for frequent requests.
- `OLLAMA_NUM_PARALLEL=1` — limits concurrent inference requests. On CPU-only deployments, set to 1. On GPU deployments, can be increased based on VRAM.

**Model pre-pull:**

After Ollama is installed and the environment variables are set, the required models must be downloaded and cached locally. This step requires an internet connection and may take significant time depending on bandwidth.

Models to pre-pull:

- `llama3.1:8b-q4_K_M` — primary extraction LLM. The `q4_K_M` quantization balances quality and memory footprint. On systems with 16 GB RAM and no GPU, this is the recommended configuration. On systems with a GPU and 24 GB VRAM, consider `llama3.1:8b` (full precision).
- `nomic-embed-text` — embedding model for semantic search. Lightweight and fast. Required for the vector indexing step in Phase 3.

After pulling, verify both models are loadable by running a test inference through the Ollama API. If the model loads and returns a response, the installation is correct.

**The wait-for-ollama gate:**

Write a shell script at `/opt/docmaster/bin/wait-for-ollama.sh` that polls the Ollama health endpoint (`http://127.0.0.1:11434/api/tags`) in a loop until it returns HTTP 200, then exits. This script is used as the `ExecStartPost` in the `dm-mind.service` unit file (Phase 5) to prevent dependent services from starting before Ollama is fully ready. The script should have a timeout — if Ollama does not respond within 120 seconds, the script should exit with a non-zero code so systemd knows startup failed.

### 4.4 PaddleOCR and Kraken

These are Python package dependencies that will be installed into the DocMaster Python virtual environment in Phase 3. However, their system-level native dependencies must be installed in Phase 1 so they are available when the venv is built.

**For PaddleOCR:**
- `libgomp1` — OpenMP runtime (required by PaddlePaddle)
- `libopenblas-dev` — linear algebra library
- `libjpeg-dev`, `libpng-dev`, `libtiff-dev` — image format libraries

**For Kraken:**
- `libxml2-dev`, `libxslt-dev` — XML processing libraries
- `libffi-dev` — foreign function interface (required by some Kraken dependencies)
- `python3.12-dev` — already installed, but required here explicitly because Kraken builds native extensions

### 4.5 Manifest Lock File

When all packages are installed, generate the manifest file. This file is the authoritative record of exactly what is installed on the appliance.

**Location:** `/opt/docmaster/vault/manifest.lock`

**Contents:**

The manifest must capture, at minimum:

- The installed version of every system package listed in this section (output of `dpkg -l` filtered and formatted)
- The exact Ollama binary version (from `ollama --version`)
- The exact model names and their SHA-256 digest (from `ollama list` with digest output)
- The OS release information (`/etc/os-release` contents)
- The kernel version
- The Python version
- The Node.js version
- The date and time the manifest was generated (in UTC)
- A SHA-256 hash of the manifest file itself (computed after writing, appended at the end)

The manifest is read-only after generation. It is used by the Phase 8 Packer build to verify that the image matches the expected configuration, and by the Phase 5 diagnostic suite to confirm the environment has not drifted from its provisioned state.

**Format:** Plain text with clearly labeled sections. Not JSON or YAML — human readability is a priority because this file may need to be inspected in the field without tools.

---

## Track 5 — NVIDIA / GPU Setup (Conditional)

This track is only executed on hardware that includes a supported NVIDIA GPU. On CPU-only deployments, skip this track entirely. The manifest must record whether GPU setup was performed.

### 5.1 Detection

Before installing any NVIDIA software, confirm that:

- The GPU is physically present and detected by the OS (`lspci | grep -i nvidia` returns output)
- The GPU model is on NVIDIA's supported list for the driver version being installed
- The system has adequate power supply for the GPU (this is a hardware verification step, not an OS step)

If the GPU is not detected, do not proceed with NVIDIA installation. Log the detection result in the manifest.

### 5.2 Driver Installation

NVIDIA drivers must be installed from the official NVIDIA apt repository, not from the distribution's default repository (which often ships an older driver version).

- Add the NVIDIA CUDA repository and GPG key
- Install the driver package pinned to the exact version specified in the build manifest
- After installation, verify the driver is loaded: `nvidia-smi` must return the GPU model, driver version, and CUDA version without errors
- Verify the `docmaster` user can access the GPU: run `nvidia-smi` as `docmaster` — it must succeed. If it fails with a permission error, the `/dev/nvidia*` device nodes need ACL configuration.

### 5.3 CUDA Toolkit

- Install the CUDA toolkit version that corresponds to the pinned driver version. CUDA and driver versions are tightly coupled — mismatches cause cryptic runtime failures in PaddleOCR and the Ollama GPU backend.
- Install `cuda-toolkit-XX-X` (replace `XX-X` with the version numbers matching the driver)
- Add CUDA binary paths to the `docmaster` user's environment: `CUDA_HOME=/usr/local/cuda`, add `$CUDA_HOME/bin` to PATH
- Set `CUDA_VISIBLE_DEVICES=0` in the `docmaster` environment (makes GPU 0 available; adjust for multi-GPU setups)

### 5.4 Ollama GPU Validation

After CUDA is installed, re-run the Ollama test inference. Ollama auto-detects CUDA and will use the GPU if available. Verify GPU usage by checking `nvidia-smi` during an active inference request — GPU utilization should spike above 0%.

If the GPU is not being used despite CUDA being installed, check the `CUDA_VISIBLE_DEVICES` environment variable and verify that the `dm-mind.service` unit inherits it correctly.

---

## Validation Checklist

Phase 1 is not complete until every item in this checklist is confirmed on the running system. This checklist becomes the acceptance criteria for Phase 1 and is referenced by the Phase 5 diagnostic suite.

### OS Baseline
- [ ] Debian 12 or Ubuntu 24.04 LTS installed with minimal profile
- [ ] No GUI packages installed
- [ ] Hostname set to `docmaster-node-01` and confirmed with `hostname`
- [ ] Static IP assigned and persisted across reboots
- [ ] Timezone confirmed as UTC with `timedatectl status`
- [ ] NTP active and synchronized with `chronyc tracking`
- [ ] SSH accessible with key-only auth; password auth rejected
- [ ] Root SSH login rejected
- [ ] UFW active with only required ports open (`ufw status verbose`)
- [ ] `avahi-daemon`, `cups`, `bluetooth` services disabled and masked
- [ ] `snapd` removed or masked
- [ ] `unattended-upgrades` configured for security-only updates

### Users and Groups
- [ ] `docmaster` system user exists with no shell (`/bin/false` or `/usr/sbin/nologin`)
- [ ] `docgroup` group exists
- [ ] `docmaster` is a member of `docgroup`
- [ ] `docmaster` has no home directory
- [ ] `docmaster` cannot log in interactively (attempt returns error immediately)
- [ ] Admin user exists with sudo access limited to documented commands
- [ ] Admin user is NOT in `docgroup`

### Directory Structure
- [ ] `/opt/docmaster-blue/` exists with all 14 subdirectories
- [ ] `/opt/docmaster` symlink exists and points to `/opt/docmaster-blue/`
- [ ] All directories owned by `docmaster:docgroup`
- [ ] `vault/` and `tmp/` and `data/` and `queue/` have mode `700`
- [ ] All other directories have mode `750` except `ingest/` which has `770`
- [ ] Admin user cannot read `/opt/docmaster/vault/` contents (permission denied)

### Dependencies
- [ ] PostgreSQL 16 installed from PGDG repository; `psql --version` confirms 16.x
- [ ] `pgvector` extension package installed
- [ ] Redis 7.x installed from official repository; `redis-server --version` confirms 7.x
- [ ] Python 3.12 installed; `python3.12 --version` confirms
- [ ] Node.js 22 LTS installed; `node --version` confirms v22.x
- [ ] Tesseract 5 installed; `tesseract --version` confirms 5.x
- [ ] `poppler-utils` installed; `pdftoppm -v` runs without error
- [ ] `ffmpeg` installed; `ffmpeg -version` runs without error
- [ ] OpenCV native dependencies installed (verify with `ldconfig -p | grep libGL`)
- [ ] `postfix` installed in local-only mode
- [ ] `samba` installed
- [ ] `hylafax-server` (or ICTFax equivalent) installed
- [ ] `chrony` installed and active
- [ ] `ufw` installed and active
- [ ] `jq`, `curl`, `rsync`, `lsof`, `htop` all present

### Ollama
- [ ] Ollama binary present at `/opt/docmaster/bin/ollama` owned by `docmaster:docgroup`
- [ ] `OLLAMA_MODELS` environment variable points to `/opt/docmaster/models/`
- [ ] `OLLAMA_HOST` set to `127.0.0.1:11434`
- [ ] `llama3.1:8b-q4_K_M` model downloaded and present in `/opt/docmaster/models/`
- [ ] `nomic-embed-text` model downloaded and present in `/opt/docmaster/models/`
- [ ] Test inference returns a valid response when run as `docmaster` user
- [ ] Ollama API not accessible from outside the machine (test from another host — connection must be refused)
- [ ] `wait-for-ollama.sh` script present at `/opt/docmaster/bin/` and executable

### Manifest
- [ ] `/opt/docmaster/vault/manifest.lock` exists and is readable
- [ ] Manifest contains all package versions, model digests, and OS information
- [ ] Manifest file is owned by `docmaster:docgroup` with mode `440` (read-only)
- [ ] Manifest SHA-256 hash is recorded at the bottom of the manifest file

### GPU (if applicable)
- [ ] `nvidia-smi` returns GPU info without error
- [ ] `docmaster` user can run `nvidia-smi` without sudo
- [ ] CUDA toolkit installed and `nvcc --version` confirms the version
- [ ] Ollama uses GPU during inference (confirmed via `nvidia-smi` during active inference)

---

## Common Failure Points & Mitigation

The following are the most common issues encountered during Phase 1 provisioning. They are documented here so they can be resolved quickly rather than diagnosed from scratch.

**Ollama fails to start as `docmaster` user:**  
Most commonly caused by the `OLLAMA_MODELS` directory not being owned by `docmaster`, or by the `OLLAMA_HOST` variable not being set in the correct environment context. Verify with `sudo -u docmaster /opt/docmaster/bin/ollama serve` run manually and inspect the error output.

**PostgreSQL package conflicts with distribution version:**  
If the distribution has a pre-installed older PostgreSQL version, the PGDG repository installation may conflict. Remove the distribution-provided package first, then install from PGDG.

**Tesseract returns empty output on test:**  
The LSTM data files may not be installed. Verify with `ls /usr/share/tessdata/` — the directory should contain `.traineddata` files for each installed language. If the directory is empty or only contains the legacy OSD file, the language pack installation failed silently.

**Fax modem not recognized:**  
USB fax modems are not always auto-detected. Check `dmesg | grep -i modem` after plugging in the device. If nothing appears, the modem may need a specific kernel module. This is a hardware compatibility issue that must be resolved before Phase 4 can configure the fax ingest channel.

**Static IP reverts after reboot:**  
On Ubuntu 24.04, static IP configuration is managed by `netplan`. On Debian 12, it is managed by `/etc/network/interfaces`. Ensure the correct configuration file for the distribution is being edited. Changes to the wrong file will appear to work but will not persist.

**Permissions on `/opt/docmaster/` are too wide after recursive chown:**  
The `chown -R` command sets ownership but not mode. A separate `chmod -R` command is required. The two must be run as separate operations. Verify final permissions with `stat` or `ls -la` on each directory.

---

## Phase 1 Completion Criteria

Phase 1 is formally complete when:

1. All items in the validation checklist above are checked off and confirmed on the live system
2. The manifest file is present, complete, and its SHA-256 hash is verified
3. A member of the development team has reviewed the manifest and confirmed it matches the expected build specification
4. The system has been rebooted once and all services that should not be running are confirmed as inactive, and all baseline services (chrony, ufw, sshd) are confirmed as active after the reboot
5. The Phase 1 completion is documented in the project log with the node hostname, IP address, manifest hash, and the name of the engineer who completed the verification

**Do not proceed to Phase 2 until all five criteria are met.** Phase 2 database initialization depends on a stable, correctly permissioned filesystem. An error in Phase 1 permissions will not manifest until Phase 2 or later, at which point the root cause becomes much harder to trace.

---

*DocMaster Master Implementation Plan — Phase 1 Blueprint*  
*Revision 1.0 — Confidential — Internal Engineering Use Only*
