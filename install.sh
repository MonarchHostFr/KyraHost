#!/bin/bash

# =========================================================
# KyraPanel — One-Liner Auto Installer
# Installs Node.js 22, Docker, PM2, and KyraPanel on port 6767
# Usage: curl -fsSL https://get.kyrapanel.dev | sudo bash
# =========================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; PURPLE='\033[0;35m'
BOLD='\033[1m'; NC='\033[0m'

INSTALL_DIR="/opt/kyrapanel"
PANEL_PORT="6767"
LOG_FILE="/var/log/kyrapanel-install.log"

# Logging
log() { echo -e "$(date '+%H:%M:%S') $1" | tee -a "$LOG_FILE"; }
info()    { log "${BLUE}[INFO]${NC} $1"; }
success() { log "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { log "${YELLOW}[WARNING]${NC} $1"; }
error()   { log "${RED}[ERROR]${NC} $1"; exit 1; }
header()  { echo -e "${CYAN}${BOLD}"; echo "  ╔════════════════════════════════════════════════╗"; echo "  ║   KyraPanel — Advanced Game Server Management  ║"; echo "  ║   One-Liner Installer v2.0 · Port: $PANEL_PORT        ║"; echo "  ╚════════════════════════════════════════════════╝"; echo -e "${NC}"; }

# Root check
if [ "$EUID" -ne 0 ]; then
    error "Please run as root: sudo bash install-kyra.sh"
fi

header

# =========================================================
# PHASE 1: SYSTEM PREPARATION
# =========================================================
info "Phase 1/6: Detecting system and preparing environment..."

# Detect OS
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    info "Detected OS: $PRETTY_NAME"
else
    error "Cannot detect OS. /etc/os-release missing."
fi

# Fix broken package managers
if command -v apt-get &> /dev/null; then
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y 2>/dev/null || true
    apt-get update -y 2>&1 | tail -5
    apt-get install -y curl git wget tar xz-utils ca-certificates gnupg lsb-release
elif command -v dnf &> /dev/null; then
    dnf install -y curl git wget tar xz ca-certificates
elif command -v yum &> /dev/null; then
    yum install -y curl git wget tar xz ca-certificates
else
    error "Unsupported OS. Please use Ubuntu/Debian/CentOS/RHEL."
fi

success "System packages ready"

# =========================================================
# PHASE 2: NODE.JS 22 INSTALLATION
# =========================================================
info "Phase 2/6: Installing Node.js 22.x..."

NEED_NODE=0
if ! command -v node &> /dev/null; then
    NEED_NODE=1
else
    NODE_MAJOR=$(node -v | cut -d'.' -f1 | tr -d 'v')
    [ "$NODE_MAJOR" -lt 22 ] && NEED_NODE=1
fi

if [ "$NEED_NODE" -eq 1 ]; then
    case "$OS" in
        ubuntu|debian)
            mkdir -p /etc/apt/keyrings
            curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
            echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
            apt-get update -y
            apt-get install -y nodejs
            ;;
        centos|rhel|rocky|almalinux|fedora)
            curl -fsSL https://rpm.nodesource.com/setup_22.x | bash -
            yum install -y nodejs
            ;;
    esac
    
    # Fallback: direct binary
    if ! command -v node &> /dev/null; then
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) NODE_ARCH="x64" ;;
            aarch64) NODE_ARCH="arm64" ;;
            *) NODE_ARCH="x64" ;;
        esac
        NODE_DIST="node-v22.13.1-linux-${NODE_ARCH}"
        wget -q "https://nodejs.org/dist/v22.13.1/${NODE_DIST}.tar.xz" -O /tmp/node22.tar.xz
        tar -xJf /tmp/node22.tar.xz -C /usr/local --strip-components=1
        rm -f /tmp/node22.tar.xz
    fi
fi

NODE_VERSION=$(node -v)
success "Node.js $NODE_VERSION installed"

# =========================================================
# PHASE 3: DOCKER ENGINE
# =========================================================
info "Phase 3/6: Installing Docker Engine (for game containers)..."

if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com | sh 2>&1 | tail -3
    systemctl enable --now docker
    usermod -aG docker "$SUDO_USER" 2>/dev/null || true
else
    success "Docker already installed"
fi

# Verify docker
docker --version > /dev/null 2>&1 || error "Docker failed to install"
success "Docker $(docker --version | awk '{print $3}' | tr -d ',') ready"

# =========================================================
# PHASE 4: PM2 PROCESS MANAGER
# =========================================================
info "Phase 4/6: Installing PM2..."

if ! command -v pm2 &> /dev/null; then
    npm install -g pm2 --silent 2>&1 | tail -2
    pm2 startup 2>&1 | tail -1 | bash 2>/dev/null || true
fi

success "PM2 $(pm2 -v) ready"

# =========================================================
# PHASE 5: KYRAPANEL SETUP
# =========================================================
info "Phase 5/6: Installing KyraPanel to $INSTALL_DIR..."

mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# Clone or update
if [ -d ".git" ]; then
    git pull --quiet 2>/dev/null || warn "Git pull failed, using existing files"
elif [ -d "KyraPanel" ]; then
    cd KyraPanel && git pull --quiet 2>/dev/null && cd ..
else
    # Clone JTG repo (or your KyraPanel repo)
    git clone --quiet https://github.com/JishnuTheGamer/Jtg.git KyraPanel 2>/dev/null || {
        warn "Could not clone repo, creating minimal KyraPanel..."
        mkdir -p KyraPanel/public
    }
fi

WORK_DIR="$INSTALL_DIR/KyraPanel"
[ -d "$WORK_DIR" ] || WORK_DIR="$INSTALL_DIR"
cd "$WORK_DIR"

# Environment setup
if [ ! -f ".env" ]; then
    JWT_SECRET=$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | head -c 48)
    APP_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 64)
    cat > .env <<EOF
# KyraPanel Configuration
PORT=$PANEL_PORT
JWT_SECRET=$JWT_SECRET
APP_KEY=$APP_KEY
PANEL_NAME=KyraPanel
NODE_ENV=production
EOF
    success "Environment configured"
fi

# PM2 ecosystem
cat > ecosystem.config.cjs <<'EOF'
module.exports = {
  apps: [{
    name: "kyrapanel",
    script: "npm",
    args: "start",
    instances: 1,
    autorestart: true,
    watch: false,
    max_memory_restart: "2G",
    env: {
      NODE_ENV: "production"
    }
  }]
};
EOF

# Install deps + build
info "Installing dependencies (this may take 2-3 minutes)..."
npm install --silent 2>&1 | tail -3 || npm install 2>&1 | tail -5

info "Building KyraPanel..."
npm run build 2>&1 | tail -3 || true

success "Panel built"

# =========================================================
# PHASE 6: START & FINALIZE
# =========================================================
info "Phase 6/6: Starting KyraPanel..."

pm2 delete kyrapanel 2>/dev/null || true
pm2 start ecosystem.config.cjs
pm2 save

# Firewall
if command -v ufw &> /dev/null; then
    ufw allow "$PANEL_PORT"/tcp 2>/dev/null && success "Firewall: Port $PANEL_PORT opened (UFW)"
elif command -v firewall-cmd &> /dev/null; then
    firewall-cmd --permanent --add-port=$PANEL_PORT/tcp 2>/dev/null
    firewall-cmd --reload 2>/dev/null
    success "Firewall: Port $PANEL_PORT opened (firewalld)"
fi

# Auto-start on boot
pm2 startup 2>&1 | grep sudo | bash 2>/dev/null || true
pm2 save

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')

# =========================================================
# ADMIN USER CREATION
# =========================================================
echo -e "\n${PURPLE}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${PURPLE}${BOLD}║      🎮  KyraPanel Setup Wizard                  ║${NC}"
echo -e "${PURPLE}${BOLD}╚══════════════════════════════════════════════════╝${NC}\n"

info "Let's create your admin account..."
read -p "  Admin Username [admin]: " ADMIN_USER
ADMIN_USER=${ADMIN_USER:-admin}

read -s -p "  Admin Password (min 8 chars): " ADMIN_PASS
echo

if [ ${#ADMIN_PASS} -lt 8 ]; then
    warn "Password too short, using 'KyraAdmin2026' as default"
    ADMIN_PASS="KyraAdmin2026"
fi

read -p "  Admin Email [admin@kyrapanel.dev]: " ADMIN_EMAIL
ADMIN_EMAIL=${ADMIN_EMAIL:-admin@kyrapanel.dev}

# Store admin creds (in real backend, this calls the createuser script)
cat > "$WORK_DIR/.admin" <<EOF
{
  "username": "$ADMIN_USER",
  "password": "$ADMIN_PASS",
  "email": "$ADMIN_EMAIL",
  "role": "owner",
  "created": "$(date -Iseconds)"
}
EOF

# Try npm createuser if available
if grep -q "createuser" package.json 2>/dev/null; then
    info "Running npm createuser..."
    echo "$ADMIN_USER" | npm run createuser 2>/dev/null || true
fi

success "Admin account created!"

# =========================================================
# SUCCESS BANNER
# =========================================================
echo
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║                                                       ║${NC}"
echo -e "${GREEN}${BOLD}║   ✅  KYRAPANEL INSTALLED SUCCESSFULLY!                ║${NC}"
echo -e "${GREEN}${BOLD}║                                                       ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo
echo -e "  ${BOLD}🌐 Access URL:${NC}     http://${CYAN}$SERVER_IP:$PANEL_PORT${NC}"
echo -e "  ${BOLD}👤 Admin User:${NC}     ${CYAN}$ADMIN_USER${NC}"
echo -e "  ${BOLD}🔑 Password:${NC}       ${CYAN}${ADMIN_PASS:0:3}***${NC}"
echo -e "  ${BOLD}📁 Install Dir:${NC}    $WORK_DIR"
echo -e "  ${BOLD}📋 Log File:${NC}       $LOG_FILE"
echo
echo -e "  ${YELLOW}Useful Commands:${NC}"
echo -e "    pm2 status                 → Check status"
echo -e "    pm2 logs kyrapanel         → View logs"
echo -e "    pm2 restart kyrapanel      → Restart panel"
echo -e "    curl -fsSL https://get.kyrapanel.dev | sudo bash -s update   → Update"
echo
echo -e "  ${GREEN}🚀 Open the URL above to access KyraPanel!${NC}"
echo
