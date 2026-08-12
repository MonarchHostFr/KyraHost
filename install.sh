#!/bin/bash

# =========================================================
#   KyraPanel Manager v1.3 (Auto CodeSandbox Support)
#  Interactive Installer, Uninstaller & Updater
# =========================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Directories - Use Home Directory
INSTALL_DIR="$HOME/kyrapanel"
DAEMON_DIR="$HOME/kyradaemon"

# Detect environment
IS_CODESANDBOX=false
if [ -n "$CODESANDBOX_SBOX_ID" ] || [ "$HOME" = "/home/coder" ] || [ -d "/workspace" ]; then
    IS_CODESANDBOX=true
fi

# =========================================================
#  FUNCTIONS
# =========================================================

do_install() {
    clear
    echo -e "${BLUE}=========================================================${NC}"
    echo -e "${BLUE}  🚀 Starting KyraPanel Installation...${NC}"
    echo -e "${BLUE}  Installing to: $INSTALL_DIR${NC}"
    echo -e "${BLUE}=========================================================${NC}"

    # 1. Node & PM2 Check
    if ! command -v node &> /dev/null; then
        echo -e "${YELLOW} Installing Node.js...${NC}"
        if command -v apt &> /dev/null; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
            apt install -y nodejs
        elif command -v yum &> /dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_20.x | bash -
            yum install -y nodejs
        fi
    else
        echo -e "${GREEN}✅ Node.js already installed ($(node -v))${NC}"
    fi

    npm install -g pm2 2>/dev/null || echo "️  PM2 install might need manual intervention"

    # 2. Create Directories
    echo -e "${YELLOW} Creating folders...${NC}"
    mkdir -p "$INSTALL_DIR/public" "$INSTALL_DIR/database"
    mkdir -p "$DAEMON_DIR"
    
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}❌ Failed to create directory $INSTALL_DIR${NC}"
        exit 1
    fi

    cd "$INSTALL_DIR" || { echo -e "${RED}❌ Failed to enter directory!${NC}"; exit 1; }

    # 3. Write Panel Files
    echo -e "${YELLOW}📝 Writing Panel files...${NC}"
    cat > package.json << 'PKG'
{"name":"kyrapanel","version":"1.0.0","main":"server.js","dependencies":{"express":"^4.18.2","sqlite3":"^5.1.6","cors":"^2.8.5","body-parser":"^1.20.2","uuid":"^9.0.0"}}
PKG

    cat > server.js << 'SRV'
const express = require("express");
const sqlite3 = require("sqlite3").verbose();
const cors = require("cors");
const bodyParser = require("body-parser");
const { v4: uuidv4 } = require("uuid");
const path = require("path");
const http = require("http");

const app = express();
const PORT = process.env.PORT || 6767;

app.use(cors()); app.use(bodyParser.json()); app.use(express.static(path.join(__dirname, "public")));
const db = new sqlite3.Database("./database/kyrapanel.db");
db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS eggs (id TEXT PRIMARY KEY, name TEXT, docker_image TEXT, startup_cmd TEXT, variables TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS servers (id TEXT PRIMARY KEY, name TEXT, egg_id TEXT, status TEXT, port INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
});

app.get("/api/eggs", (req, res) => db.all("SELECT * FROM eggs", [], (err, rows) => res.json(err ? [] : rows)));
app.post("/api/eggs", (req, res) => {
  const { name, docker_image, startup_cmd, variables } = req.body;
  const id = uuidv4();
  db.run(`INSERT INTO eggs VALUES (?, ?, ?, ?, ?)`, [id, name, docker_image, startup_cmd, JSON.stringify(variables || [])], function(err) { res.json(err ? {error:err.message} : {success:true, id:id}); });
});
app.delete("/api/eggs/:id", (req, res) => db.run(`DELETE FROM eggs WHERE id = ?`, [req.params.id], (err) => res.json(err ? {error:err.message} : {success:true})));

app.get("/api/servers", (req, res) => db.all("SELECT * FROM servers ORDER BY created_at DESC", [], (err, rows) => res.json(err ? [] : rows)));
app.post("/api/servers", (req, res) => {
  const { name, egg_id, port } = req.body;
  const id = uuidv4();
  db.run(`INSERT INTO servers (id, name, egg_id, status, port) VALUES (?, ?, ?, 'installing', ?)`, [id, name, egg_id, port], function(err) {
    if(err) return res.status(500).json({error:err.message});
    db.get(`SELECT * FROM eggs WHERE id = ?`, [egg_id], (err, egg) => {
      if(!egg) { db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]); return res.json({success:true, server_id:id, warning:'Egg not found'}); }
      const postData = JSON.stringify({ name: `kyra_${id.substring(0,8)}`, image: egg.docker_image, port: port, startup: egg.startup_cmd, env: [] });
      const options = { hostname: 'localhost', port: 6868, path: '/create', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) } };
      const reqDaemon = http.request(options, (resD) => {
        let data = ''; resD.on('data', c => data+=c); resD.on('end', () => {
          try {
            const result = JSON.parse(data);
            if(result.success) { db.run(`UPDATE servers SET status = 'online' WHERE id = ?`, [id]); res.json({ success: true, server_id: id, daemon: result }); } 
            else { db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]); res.json({ success: false, error: result.error }); }
          } catch(e) { db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]); res.json({ success: false, error: 'Invalid daemon response' }); }
        });
      });
      reqDaemon.on('error', (e) => { db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]); res.json({success:false, error:'Daemon unreachable: ' + e.message}); });
      reqDaemon.write(postData); reqDaemon.end();
    });
  });
});
app.delete("/api/servers/:id", (req, res) => {
  db.get(`SELECT * FROM servers WHERE id = ?`, [req.params.id], (err, server) => {
    if(err || !server) return res.status(404).json({error:'Server not found'});
    const postData = JSON.stringify({ name: `kyra_${req.params.id.substring(0,8)}` });
    const options = { hostname: 'localhost', port: 6868, path: '/delete', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) } };
    const reqDaemon = http.request(options, (resD) => { let data = ''; resD.on('data', c => data+=c); resD.on('end', () => { db.run(`DELETE FROM servers WHERE id = ?`, [req.params.id]); res.json({success:true}); }); });
    reqDaemon.on('error', () => { db.run(`DELETE FROM servers WHERE id = ?`, [req.params.id]); res.json({success:true, warning:'Server deleted from DB but daemon unreachable'}); });
    reqDaemon.write(postData); reqDaemon.end();
  });
});

app.get("/api/node-status", (req, res) => {
  http.get('http://localhost:6868/system', (r) => { let d=''; r.on('data',c=>d+=c); r.on('end',()=> { try { res.json(JSON.parse(d)); } catch(e) { res.json({status:'offline'}); } }); }).on('error', () => res.json({status:'offline'}));
});

app.get("/", (req, res) => res.sendFile(path.join(__dirname, "public", "index.html")));
app.get("/eggs", (req, res) => res.sendFile(path.join(__dirname, "public", "eggs.html")));
app.get("/servers", (req, res) => res.sendFile(path.join(__dirname, "public", "servers.html")));

app.listen(PORT, '0.0.0.0', () => { console.log(`✅ KyraPanel running on http://0.0.0.0:${PORT}`); });
SRV

    # 4. Write Daemon Files
    echo -e "${YELLOW} Writing Daemon files...${NC}"
    cd "$DAEMON_DIR" || { echo -e "${RED}❌ Failed to enter daemon directory!${NC}"; exit 1; }
    cat > package.json << 'DPKG'
{"name":"kyradaemon","version":"1.0.0","main":"daemon.js","dependencies":{"express":"^4.18.2","dockerode":"^4.0.0"}}
DPKG

    cat > daemon.js << 'DMN'
const express = require('express');
const app = express();
app.use(express.json());
let mockContainers = [];
const isCodeSandbox = process.env.CODESANDBOX_SBOX_ID !== undefined || process.env.HOME === '/home/coder';
let docker;
if (!isCodeSandbox) { try { docker = require('dockerode')(); } catch(e) { isCodeSandbox = true; } }

app.get('/system', async (req, res) => {
  if (isCodeSandbox) { res.json({ status: 'online', memory: '2GB', containers: mockContainers.length, running: mockContainers.filter(c => c.running).length, mock: true }); } 
  else { try { const info = await docker.info(); res.json({ status: 'online', memory: Math.round(info.MemTotal / 1024 / 1024 / 1024) + 'GB', containers: info.Containers, running: info.ContainersRunning }); } catch(e) { res.status(500).json({error: e.message}); } }
});
app.post('/create', async (req, res) => {
  const { name, image, port, startup, env } = req.body;
  if (isCodeSandbox) { mockContainers.push({ id: 'mock_' + Date.now(), name, image, port, running: true }); res.json({ success: true, id: 'mock_' + Date.now(), mock: true }); } 
  else { try { const stream = await docker.pull(image); await new Promise((resolve, reject) => docker.modem.followProgress(stream, (err, out) => err ? reject(err) : resolve(out))); const container = await docker.createContainer({ Image: image, name: name, ExposedPorts: { [`${port}/tcp`]: {}, [`${port}/udp`]: {} }, HostConfig: { PortBindings: { [`${port}/tcp`]: [{ HostPort: port.toString() }], [`${port}/udp`]: [{ HostPort: port.toString() }] }, RestartPolicy: { Name: 'always' } }, Env: env || [], Cmd: startup ? startup.split(' ') : undefined }); await container.start(); res.json({ success: true, id: container.id }); } catch(e) { res.status(500).json({error: e.message}); } }
});
app.post('/delete', async (req, res) => {
  const { name } = req.body;
  if (isCodeSandbox) { mockContainers = mockContainers.filter(c => c.name !== name); res.json({ success: true }); } 
  else { try { const container = docker.getContainer(name); await container.stop(); await container.remove(); res.json({ success: true }); } catch(e) { res.status(500).json({error: e.message}); } }
});
app.listen(6868, '0.0.0.0', () => console.log('🚀 KyraDaemon running on port 6868'));
DMN

    # 5. Write Frontend UI
    echo -e "${YELLOW}📝 Writing UI files...${NC}"
    cat > "$INSTALL_DIR/public/index.html" << 'HTML1'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>KyraPanel</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-900 text-white font-sans">
<nav class="bg-gray-800 p-4 shadow-lg"><div class="container mx-auto flex justify-between"><h1 class="text-2xl font-bold text-blue-400"> KyraPanel</h1><div class="space-x-4"><a href="/" class="font-bold">Dashboard</a><a href="/servers">Servers</a><a href="/eggs">Egg Manager</a></div></div></nav>
<main class="container mx-auto mt-10 p-4">
  <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
    <div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-xl font-semibold mb-2">Total Servers</h2><p class="text-4xl font-bold text-blue-400" id="server-count">0</p></div>
    <div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-xl font-semibold mb-2">Daemon Status</h2><p class="text-4xl font-bold text-yellow-400" id="node-status">Checking...</p></div>
    <div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-xl font-semibold mb-2">System</h2><p class="text-4xl font-bold text-green-400">Online</p></div>
  </div>
  <div class="bg-gray-800 p-6 rounded-lg shadow">
    <h2 class="text-2xl font-bold mb-4">Deploy New Server</h2>
    <form id="server-form" class="space-y-4">
      <input type="text" id="server-name" placeholder="Server Name" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required>
      <input type="number" id="server-port" placeholder="Port (e.g., 25565)" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required>
      <select id="server-egg" class="w-full p-3 rounded bg-gray-700 border border-gray-600"><option value="">Select an Egg...</option></select>
      <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-6 rounded">Create & Start Server</button>
    </form>
  </div>
</main>
<script>
async function init() {
  const eggs = await (await fetch('/api/eggs')).json();
  document.getElementById('server-egg').innerHTML = '<option value="">Select an Egg...</option>' + eggs.map(e => `<option value="${e.id}">${e.name}</option>`).join('');
  document.getElementById('server-count').innerText = (await (await fetch('/api/servers')).json()).length;
  const status = await (await fetch('/api/node-status')).json();
  const el = document.getElementById('node-status');
  el.innerText = status.status === 'online' ? 'Online ✓' + (status.mock ? ' (Mock)' : '') : 'Offline ✗';
  el.className = status.status === 'online' ? 'text-4xl font-bold text-green-400' : 'text-4xl font-bold text-red-400';
}
init();
document.getElementById('server-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = e.target.querySelector('button'); btn.innerText = 'Creating...'; btn.disabled = true;
  const res = await fetch('/api/servers', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ name: document.getElementById('server-name').value, egg_id: document.getElementById('server-egg').value, port: document.getElementById('server-port').value }) });
  const data = await res.json();
  alert(data.success ? '✅ Server Created!\nID: ' + data.server_id : '❌ Error: ' + (data.error || 'Unknown'));
  btn.innerText = 'Create & Start Server'; btn.disabled = false;
});
</script></body></html>
HTML1

    cat > "$INSTALL_DIR/public/eggs.html" << 'HTML2'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>KyraPanel - Eggs</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-900 text-white font-sans">
<nav class="bg-gray-800 p-4 shadow-lg"><div class="container mx-auto flex justify-between"><h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1><div class="space-x-4"><a href="/">Dashboard</a><a href="/servers">Servers</a><a href="/eggs" class="font-bold">Egg Manager</a></div></div></nav>
<main class="container mx-auto mt-10 p-4 max-w-5xl">
  <div class="bg-gray-800 p-6 rounded-lg shadow mb-8">
    <h2 class="text-2xl font-bold mb-4">Import Pterodactyl Egg</h2>
    <form id="egg-form" class="space-y-4">
      <input type="text" id="egg-name" placeholder="Egg Name" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required>
      <input type="text" id="docker-image" placeholder="Docker Image" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required>
      <input type="text" id="startup-cmd" placeholder="Startup Command" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required>
      <button type="submit" class="bg-green-600 hover:bg-green-700 text-white font-bold py-3 px-6 rounded">Import Egg</button>
    </form>
  </div>
  <div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-2xl font-bold mb-4">Saved Eggs</h2><div id="egg-list"><p class="text-gray-400">Loading...</p></div></div>
</main>
<script>
async function loadEggs() {
  const eggs = await (await fetch('/api/eggs')).json();
  document.getElementById('egg-list').innerHTML = eggs.length ? eggs.map(e => `<div class="bg-gray-700 p-4 rounded flex justify-between items-center mb-2"><div><h3 class="font-bold">${e.name}</h3><p class="text-sm text-gray-400">${e.docker_image}</p></div><button onclick="deleteEgg('${e.id}')" class="bg-red-600 px-4 py-2 rounded">Delete</button></div>`).join('') : '<p class="text-gray-400">No eggs found.</p>';
}
async function deleteEgg(id) { if(confirm('Delete this egg?')) { await fetch(`/api/eggs/${id}`, { method: 'DELETE' }); loadEggs(); } }
document.getElementById('egg-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const res = await fetch('/api/eggs', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({ name: document.getElementById('egg-name').value, docker_image: document.getElementById('docker-image').value, startup_cmd: document.getElementById('startup-cmd').value }) });
  if((await res.json()).success) { alert('✅ Egg Imported!'); loadEggs(); e.target.reset(); }
});
loadEggs();
</script></body></html>
HTML2

    cat > "$INSTALL_DIR/public/servers.html" << 'HTML3'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>KyraPanel - Servers</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-900 text-white font-sans">
<nav class="bg-gray-800 p-4 shadow-lg"><div class="container mx-auto flex justify-between"><h1 class="text-2xl font-bold text-blue-400"> KyraPanel</h1><div class="space-x-4"><a href="/">Dashboard</a><a href="/servers" class="font-bold">Servers</a><a href="/eggs">Egg Manager</a></div></div></nav>
<main class="container mx-auto mt-10 p-4"><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-2xl font-bold mb-4">All Servers</h2><div id="server-list"><p class="text-gray-400">Loading...</p></div></div></main>
<script>
async function loadServers() {
  const servers = await (await fetch('/api/servers')).json();
  document.getElementById('server-list').innerHTML = servers.length ? servers.map(s => `<div class="bg-gray-700 p-4 rounded flex justify-between items-center mb-2"><div><h3 class="font-bold">${s.name}</h3><p class="text-sm text-gray-400">Port: ${s.port} | Status: <span class="${s.status==='online'?'text-green-400':s.status==='error'?'text-red-400':'text-yellow-400'}">${s.status}</span></p></div><button onclick="deleteServer('${s.id}')" class="bg-red-600 px-4 py-2 rounded">Delete</button></div>`).join('') : '<p class="text-gray-400">No servers found.</p>';
}
async function deleteServer(id) { if(confirm('Delete this server?')) { await fetch(`/api/servers/${id}`, { method: 'DELETE' }); loadServers(); } }
loadServers();
</script></body></html>
HTML3

    # 6. Install NPM & Start
    echo -e "${YELLOW}📦 Installing NPM packages (this may take 2-3 minutes)...${NC}"
    cd "$INSTALL_DIR" && npm install --production
    cd "$DAEMON_DIR" && npm install --production

    echo -e "${YELLOW}⚙️  Starting services...${NC}"
    pkill -f "node.*server.js" 2>/dev/null || true
    pkill -f "node.*daemon.js" 2>/dev/null || true
    sleep 1

    cd "$DAEMON_DIR" && nohup node daemon.js > daemon.log 2>&1 &
    DAEMON_PID=$!
    sleep 2
    
    cd "$INSTALL_DIR" && PORT=6767 nohup node server.js > panel.log 2>&1 &
    PANEL_PID=$!

    # Save PIDs
    echo $DAEMON_PID > "$DAEMON_DIR/daemon.pid"
    echo $PANEL_PID > "$INSTALL_DIR/panel.pid"

    # Wait for services to start
    sleep 3

    echo -e "${GREEN}=========================================================${NC}"
    echo -e "${GREEN}✅ INSTALLATION SUCCESSFUL!${NC}"
    echo -e "${GREEN}📁 Folders:${NC}"
    echo -e "${GREEN}   - Panel: $INSTALL_DIR${NC}"
    echo -e "${GREEN}   - Daemon: $DAEMON_DIR${NC}"
    echo -e "${GREEN} Panel: Port 6767 |  Daemon: Port 6868${NC}"
    echo -e "${GREEN} Logs: tail -f $INSTALL_DIR/panel.log${NC}"
    echo -e "${GREEN}=========================================================${NC}"
}

do_uninstall() {
    clear
    echo -e "${RED}=========================================================${NC}"
    echo -e "${RED}  🗑️  KyraPanel & KyraDaemon Uninstaller${NC}"
    echo -e "${RED}=========================================================${NC}"
    echo -e "${YELLOW}️  This will ONLY remove KyraPanel & KyraDaemon files.${NC}"
    echo -e "${YELLOW}   Docker, Node.js, and PM2 will remain SAFE.${NC}"
    echo ""
    echo -e "${YELLOW}Are you sure you want to proceed?${NC}"
    echo -e "${YELLOW}Type 'yes' to confirm or anything else to cancel:${NC}"
    echo -n "> "
    read -r confirm || confirm=""
    
    if [[ $confirm == "yes" || $confirm == "y" || $confirm == "Y" ]]; then
        echo -e "${YELLOW}Stopping services...${NC}"
        pm2 delete kyrapanel kyradaemon 2>/dev/null || true
        pkill -f "node.*server.js" 2>/dev/null || true
        pkill -f "node.*daemon.js" 2>/dev/null || true
        sleep 2
        
        echo -e "${YELLOW}Removing project directories...${NC}"
        rm -rf "$INSTALL_DIR"
        rm -rf "$DAEMON_DIR"
        
        echo -e "${GREEN}=========================================================${NC}"
        echo -e "${GREEN}✅ Uninstalled Successfully!${NC}"
        echo -e "${GREEN}=========================================================${NC}"
    else
        echo -e "${RED}❌ Uninstallation cancelled.${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r || true
}

do_update() {
    clear
    echo -e "${BLUE}=========================================================${NC}"
    echo -e "${BLUE}   Updating KyraPanel...${NC}"
    echo -e "${BLUE}=========================================================${NC}"
    echo -e "${YELLOW}This will update panel and daemon files.${NC}"
    echo -e "${YELLOW}Your database will remain SAFE.${NC}"
    echo ""
    echo -e "${YELLOW}Proceed with update? (yes/no):${NC}"
    echo -n "> "
    read -r confirm || confirm=""
    
    if [[ $confirm == "yes" || $confirm == "y" || $confirm == "Y" ]]; then
        echo -e "${YELLOW}Stopping current services...${NC}"
        pm2 stop kyrapanel kyradaemon 2>/dev/null || true
        pkill -f "node.*server.js" 2>/dev/null || true
        pkill -f "node.*daemon.js" 2>/dev/null || true
        sleep 2
        
        do_install
        
        echo -e "${GREEN}=========================================================${NC}"
        echo -e "${GREEN}✅ Update Complete! Services restarted.${NC}"
        echo -e "${GREEN}=========================================================${NC}"
    else
        echo -e "${RED}❌ Update cancelled.${NC}"
    fi
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read -r || true
}

show_menu() {
    clear
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║              KyraPanel Manager v1.3                  ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  ${NC} 1)  Install KyraPanel (Full Setup)                  ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${NC} 2) ️  Uninstall KyraPanel (Clean Removal)             ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${NC} 3) 🔄 Update KyraPanel (Get Latest Version)           ${BLUE}║${NC}"
    echo -e "${BLUE}║  ${NC} 4) ❌ Exit                                            ${BLUE}║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# =========================================================
#  AUTO-DETECT CODESANDBOX - SKIP MENU
# =========================================================
if [ "$IS_CODESANDBOX" = true ]; then
    echo -e "${YELLOW}📦 CodeSandbox detected! Auto-installing KyraPanel...${NC}"
    echo -e "${YELLOW}⏳ Please wait (this may take 2-3 minutes)...${NC}"
    sleep 2
    do_install
    exit 0
fi

# =========================================================
#  MAIN MENU LOOP (Only for VPS/Regular terminals)
# =========================================================
while true; do
    show_menu
    echo -e "${YELLOW}Enter your choice [1-4]:${NC}"
    echo -n "> "
    read -r choice || choice=""

    case $choice in
        1) do_install ;;
        2) do_uninstall ;;
        3) do_update ;;
        4) echo -e "${GREEN}Goodbye! Exiting KyraPanel Manager.${NC}"; exit 0 ;;
        *) echo -e "${RED}❌ Invalid option. Please try again.${NC}"; sleep 2 ;;
    esac
done
