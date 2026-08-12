#!/bin/bash

INSTALL_DIR="$HOME/kyrapanel"
DAEMON_DIR="$HOME/kyradaemon"

# ==========================================
# FUNCTIONS
# ==========================================

do_install() {
    echo "🚀 Starting KyraPanel Installation..."
    mkdir -p "$INSTALL_DIR/public" "$INSTALL_DIR/database" "$DAEMON_DIR"
    
    # 1. Panel Backend (Auth, Roles, API, Egg Import)
    cat > "$INSTALL_DIR/package.json" << 'EOF'
{"name":"kyrapanel","version":"2.1.0","main":"server.js","dependencies":{"express":"^4.18.2","sqlite3":"^5.1.6","crypto":"^1.0.1"}}
EOF

    cat > "$INSTALL_DIR/server.js" << 'EOF'
const express = require("express");
const sqlite3 = require("sqlite3").verbose();
const crypto = require("crypto");
const path = require("path");

const app = express();
const PORT = process.env.PORT || 6767;

app.use(express.json({ limit: '10mb' })); // Allow large JSON for egg imports
app.use(express.static(path.join(__dirname, "public")));

const db = new sqlite3.Database("./database/kyrapanel.db");
db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS users (id TEXT PRIMARY KEY, username TEXT UNIQUE, password_hash TEXT, role TEXT, auth_token TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS eggs (id TEXT PRIMARY KEY, name TEXT, docker_image TEXT, startup TEXT, variables TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS servers (id TEXT PRIMARY KEY, user_id TEXT, egg_id TEXT, name TEXT, port INTEGER, status TEXT)`);
  
  // Default Admin: username 'admin', password 'admin123'
  const adminHash = crypto.createHash('sha256').update('admin123').digest('hex');
  db.run(`INSERT OR IGNORE INTO users (id, username, password_hash, role) VALUES ('admin-1', 'admin', ?, 'admin')`, [adminHash]);
});

const hash = (pwd) => crypto.createHash('sha256').update(pwd).digest('hex');
const genToken = () => crypto.randomBytes(32).toString('hex');

const requireAuth = (req, res, next) => {
  const authHeader = req.headers.authorization;
  if (!authHeader) return res.status(401).json({ error: "No token provided" });
  const token = authHeader.split(' ')[1];
  db.get("SELECT * FROM users WHERE auth_token = ?", [token], (err, user) => {
    if (err || !user) return res.status(401).json({ error: "Invalid token" });
    req.user = user;
    next();
  });
};

const requireAdmin = (req, res, next) => {
  if (req.user.role !== 'admin') return res.status(403).json({ error: "Admin access required" });
  next();
};

// --- AUTH ---
app.post("/api/register", (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) return res.status(400).json({ error: "Missing fields" });
  const id = "user-" + Date.now();
  const pwdHash = hash(password);
  const token = genToken();
  db.run("INSERT INTO users (id, username, password_hash, role, auth_token) VALUES (?, ?, ?, 'user', ?)", [id, username, pwdHash, token], function(err) {
    if (err) return res.status(400).json({ error: "Username already taken" });
    res.json({ success: true, token, role: 'user', username });
  });
});

app.post("/api/login", (req, res) => {
  const { username, password } = req.body;
  const pwdHash = hash(password);
  db.get("SELECT * FROM users WHERE username = ? AND password_hash = ?", [username, pwdHash], (err, user) => {
    if (!user) return res.status(401).json({ error: "Invalid credentials" });
    const token = genToken();
    db.run("UPDATE users SET auth_token = ? WHERE id = ?", [token, user.id]);
    res.json({ success: true, token, role: user.role, username: user.username });
  });
});

app.get("/api/me", requireAuth, (req, res) => res.json({ username: req.user.username, role: req.user.role }));

// --- EGGS (With Pterodactyl JSON Import) ---
app.get("/api/eggs", (req, res) => {
  db.all("SELECT id, name, docker_image FROM eggs", [], (err, rows) => res.json(err ? [] : rows));
});

app.post("/api/eggs/import", requireAuth, requireAdmin, (req, res) => {
  try {
    const pteroEgg = req.body; // Expects full Pterodactyl egg JSON
    const id = "egg-" + Date.now();
    const name = pteroEgg.name || "Imported Egg";
    const docker_image = pteroEgg.docker_image || "ubuntu:20.04";
    const startup = pteroEgg.startup || "echo 'No startup command'";
    const variables = JSON.stringify(pteroEgg.variables || []);
    
    db.run("INSERT INTO eggs (id, name, docker_image, startup, variables) VALUES (?, ?, ?, ?, ?)", 
      [id, name, docker_image, startup, variables], function(err) {
        if (err) return res.status(500).json({ error: err.message });
        res.json({ success: true, message: "Pterodactyl Egg imported successfully!" });
      });
  } catch (e) {
    res.status(400).json({ error: "Invalid JSON format" });
  }
});

app.delete("/api/eggs/:id", requireAuth, requireAdmin, (req, res) => {
  db.run("DELETE FROM eggs WHERE id = ?", [req.params.id], (err) => res.json(err ? { error: err.message } : { success: true }));
});

// --- SERVERS ---
app.get("/api/servers", requireAuth, (req, res) => {
  if (req.user.role === 'admin') {
    db.all("SELECT servers.*, users.username FROM servers LEFT JOIN users ON servers.user_id = users.id", [], (err, rows) => res.json(err ? [] : rows));
  } else {
    db.all("SELECT * FROM servers WHERE user_id = ?", [req.user.id], (err, rows) => res.json(err ? [] : rows));
  }
});

app.post("/api/servers", requireAuth, requireAdmin, (req, res) => {
  const { user_id, egg_id, name, port } = req.body;
  const id = "srv-" + Date.now();
  db.run("INSERT INTO servers (id, user_id, egg_id, name, port, status) VALUES (?, ?, ?, ?, ?, 'offline')", [id, user_id, egg_id, name, port], function(err) {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ success: true, server_id: id });
  });
});

app.delete("/api/servers/:id", requireAuth, requireAdmin, (req, res) => {
  db.run("DELETE FROM servers WHERE id = ?", [req.params.id], (err) => res.json(err ? { error: err.message } : { success: true }));
});

// --- USERS (Admin Only) ---
app.get("/api/users", requireAuth, requireAdmin, (req, res) => {
  db.all("SELECT id, username, role FROM users", [], (err, rows) => res.json(err ? [] : rows));
});

app.listen(PORT, () => console.log(`✅ KyraPanel running on http://0.0.0.0:${PORT}`));
EOF

    # 2. Daemon
    cat > "$DAEMON_DIR/package.json" << 'EOF'
{"name":"kyradaemon","version":"1.0.0","main":"daemon.js","dependencies":{"express":"^4.18.2"}}
EOF
    cat > "$DAEMON_DIR/daemon.js" << 'EOF'
const express = require('express');
const app = express();
app.use(express.json());
app.get('/system', (req, res) => res.json({ status: 'online', memory: '2GB', containers: 0 }));
app.listen(6868, () => console.log('🚀 KyraDaemon running on port 6868'));
EOF

    # 3. Frontend (SPA with Egg Import)
    cat > "$INSTALL_DIR/public/index.html" << 'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>KyraPanel v2.1</title><script src="https://cdn.tailwindcss.com"></script></head>
<body class="bg-gray-900 text-white font-sans min-h-screen flex flex-col">
<nav class="bg-gray-800 p-4 shadow-lg flex justify-between items-center">
  <h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1>
  <div id="nav-links" class="hidden space-x-4 items-center">
    <span id="user-display" class="text-gray-300"></span>
    <button onclick="logout()" class="bg-red-600 hover:bg-red-700 px-3 py-1 rounded text-sm">Logout</button>
  </div>
</nav>

<main class="flex-grow container mx-auto p-4">
  <!-- Login View -->
  <div id="login-view" class="max-w-md mx-auto mt-10 bg-gray-800 p-6 rounded-lg shadow">
    <h2 class="text-2xl font-bold mb-4 text-center">Login</h2>
    <form onsubmit="handleLogin(event)" class="space-y-4">
      <input type="text" id="login-user" placeholder="Username" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-blue-500 outline-none" required>
      <input type="password" id="login-pass" placeholder="Password" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-blue-500 outline-none" required>
      <button type="submit" class="w-full bg-blue-600 hover:bg-blue-700 py-3 rounded font-bold transition">Login</button>
    </form>
    <p class="mt-4 text-sm text-center text-gray-400">No account? <a href="#" onclick="showView('register-view')" class="text-blue-400 hover:underline">Register</a></p>
    <p class="mt-2 text-xs text-center text-yellow-400">Default Admin: <b>admin</b> / <b>admin123</b></p>
  </div>

  <!-- Register View -->
  <div id="register-view" class="hidden max-w-md mx-auto mt-10 bg-gray-800 p-6 rounded-lg shadow">
    <h2 class="text-2xl font-bold mb-4 text-center">Register</h2>
    <form onsubmit="handleRegister(event)" class="space-y-4">
      <input type="text" id="reg-user" placeholder="Username" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-green-500 outline-none" required>
      <input type="password" id="reg-pass" placeholder="Password" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-green-500 outline-none" required>
      <button type="submit" class="w-full bg-green-600 hover:bg-green-700 py-3 rounded font-bold transition">Register</button>
    </form>
    <p class="mt-4 text-sm text-center text-gray-400">Have an account? <a href="#" onclick="showView('login-view')" class="text-blue-400 hover:underline">Login</a></p>
  </div>

  <!-- Admin View -->
  <div id="admin-view" class="hidden space-y-6">
    <h2 class="text-3xl font-bold text-blue-400">Admin Dashboard</h2>
    
    <!-- Egg Import Section -->
    <div class="bg-gray-800 p-6 rounded-lg shadow">
      <h3 class="text-xl font-bold mb-4 flex items-center"><span class="mr-2">🥚</span> Import Pterodactyl Egg (.json)</h3>
      <form onsubmit="importEgg(event)" class="space-y-4">
        <textarea id="egg-json" rows="8" placeholder='Paste Pterodactyl Egg JSON here... (e.g., {"name": "Minecraft", "docker_image": "ghcr.io/...", "startup": "java -jar server.jar", "variables": []})' class="w-full p-3 rounded bg-gray-700 border border-gray-600 font-mono text-sm focus:border-blue-500 outline-none" required></textarea>
        <button type="submit" class="bg-purple-600 hover:bg-purple-700 px-6 py-2 rounded font-bold transition">Import Egg</button>
      </form>
    </div>

    <!-- Create Server Section -->
    <div class="bg-gray-800 p-6 rounded-lg shadow">
      <h3 class="text-xl font-bold mb-4 flex items-center"><span class="mr-2">🖥️</span> Create Server for User</h3>
      <form onsubmit="createServer(event)" class="grid grid-cols-1 md:grid-cols-4 gap-4">
        <select id="admin-user-select" class="p-3 rounded bg-gray-700 border border-gray-600 outline-none" required><option value="">Select User</option></select>
        <select id="admin-egg-select" class="p-3 rounded bg-gray-700 border border-gray-600 outline-none" required><option value="">Select Egg</option></select>
        <input type="text" id="srv-name" placeholder="Server Name" class="p-3 rounded bg-gray-700 border border-gray-600 outline-none" required>
        <input type="number" id="srv-port" placeholder="Port" class="p-3 rounded bg-gray-700 border border-gray-600 outline-none" required>
        <button type="submit" class="md:col-span-4 bg-blue-600 hover:bg-blue-700 py-3 rounded font-bold transition">Create Server</button>
      </form>
    </div>

    <!-- Servers List -->
    <div class="bg-gray-800 p-6 rounded-lg shadow">
      <h3 class="text-xl font-bold mb-4">All Servers</h3>
      <div id="admin-server-list" class="space-y-2"></div>
    </div>
  </div>

  <!-- User View -->
  <div id="user-view" class="hidden">
    <h2 class="text-3xl font-bold mb-6 text-green-400">My Servers</h2>
    <div id="user-server-list" class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4"></div>
  </div>
</main>

<script>
let token = localStorage.getItem('kyra_token');
let currentUser = null;

async function checkAuth() {
  if (!token) { showView('login-view'); return; }
  const res = await fetch('/api/me', { headers: { 'Authorization': 'Bearer ' + token } });
  if (res.ok) {
    currentUser = await res.json();
    document.getElementById('user-display').innerText = currentUser.username + ' (' + currentUser.role + ')';
    document.getElementById('nav-links').classList.remove('hidden');
    document.getElementById('nav-links').classList.add('flex');
    if (currentUser.role === 'admin') { loadAdminData(); showView('admin-view'); }
    else { loadUserServers(); showView('user-view'); }
  } else {
    localStorage.removeItem('kyra_token'); token = null; showView('login-view');
  }
}

function showView(viewId) {
  ['login-view', 'register-view', 'admin-view', 'user-view'].forEach(id => document.getElementById(id).classList.add('hidden'));
  document.getElementById(viewId).classList.remove('hidden');
}

async function handleLogin(e) {
  e.preventDefault();
  const res = await fetch('/api/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: document.getElementById('login-user').value, password: document.getElementById('login-pass').value }) });
  const data = await res.json();
  if (data.success) { localStorage.setItem('kyra_token', data.token); token = data.token; checkAuth(); }
  else alert(data.error);
}

async function handleRegister(e) {
  e.preventDefault();
  const res = await fetch('/api/register', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username: document.getElementById('reg-user').value, password: document.getElementById('reg-pass').value }) });
  const data = await res.json();
  if (data.success) { localStorage.setItem('kyra_token', data.token); token = data.token; checkAuth(); }
  else alert(data.error);
}

function logout() { localStorage.removeItem('kyra_token'); token = null; currentUser = null; document.getElementById('nav-links').classList.add('hidden'); document.getElementById('nav-links').classList.remove('flex'); showView('login-view'); }

async function loadAdminData() {
  const users = await (await fetch('/api/users', { headers: { 'Authorization': 'Bearer ' + token } })).json();
  const sel = document.getElementById('admin-user-select');
  sel.innerHTML = '<option value="">Select User</option>' + users.map(u => '<option value="' + u.id + '">' + u.username + ' (' + u.role + ')</option>').join('');
  
  const eggs = await (await fetch('/api/eggs')).json();
  const eggSel = document.getElementById('admin-egg-select');
  eggSel.innerHTML = '<option value="">Select Egg</option>' + eggs.map(e => '<option value="' + e.id + '">' + e.name + '</option>').join('');

  const servers = await (await fetch('/api/servers', { headers: { 'Authorization': 'Bearer ' + token } })).json();
  document.getElementById('admin-server-list').innerHTML = servers.length ? servers.map(s => '<div class="bg-gray-700 p-3 rounded flex justify-between items-center"><div><span class="font-bold">' + s.name + '</span> <span class="text-gray-400 text-sm">(Port: ' + s.port + ' | User: ' + (s.username || 'Unknown') + ')</span></div><button onclick="deleteServer(\'' + s.id + '\')" class="text-red-400 hover:text-red-300 text-sm">Delete</button></div>').join('') : '<p class="text-gray-400">No servers yet.</p>';
}

async function importEgg(e) {
  e.preventDefault();
  try {
    const json = JSON.parse(document.getElementById('egg-json').value);
    const res = await fetch('/api/eggs/import', { method: 'POST', headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' }, body: JSON.stringify(json) });
    const data = await res.json();
    if (data.success) { alert('✅ ' + data.message); document.getElementById('egg-json').value = ''; loadAdminData(); }
    else alert('❌ ' + data.error);
  } catch (err) { alert('❌ Invalid JSON format! Please check your Pterodactyl egg file.'); }
}

async function createServer(e) {
  e.preventDefault();
  const res = await fetch('/api/servers', { method: 'POST', headers: { 'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json' }, body: JSON.stringify({ user_id: document.getElementById('admin-user-select').value, egg_id: document.getElementById('admin-egg-select').value, name: document.getElementById('srv-name').value, port: document.getElementById('srv-port').value }) });
  if ((await res.json()).success) { alert('✅ Server Created!'); loadAdminData(); e.target.reset(); }
}

async function deleteServer(id) {
  if(!confirm('Delete this server?')) return;
  await fetch('/api/servers/' + id, { method: 'DELETE', headers: { 'Authorization': 'Bearer ' + token } });
  loadAdminData();
}

async function loadUserServers() {
  const servers = await (await fetch('/api/servers', { headers: { 'Authorization': 'Bearer ' + token } })).json();
  document.getElementById('user-server-list').innerHTML = servers.length ? servers.map(s => '<div class="bg-gray-800 p-6 rounded-lg shadow border-l-4 border-green-500"><h3 class="text-xl font-bold">' + s.name + '</h3><p class="text-gray-400 mt-1">Port: ' + s.port + '</p><div class="mt-4 flex items-center"><span class="w-3 h-3 bg-green-500 rounded-full mr-2"></span><span class="text-green-400 font-semibold">' + s.status + '</span></div></div>').join('') : '<p class="text-gray-400 bg-gray-800 p-6 rounded-lg">You have no servers. Please contact an admin.</p>';
}

checkAuth();
</script></body></html>
EOF

    # Install Dependencies & Start
    echo "📦 Installing dependencies..."
    cd "$INSTALL_DIR" && npm install >/dev/null 2>&1
    cd "$DAEMON_DIR" && npm install >/dev/null 2>&1
    
    echo "⚙️ Starting services..."
    pkill -f "node.*server.js" 2>/dev/null || true
    pkill -f "node.*daemon.js" 2>/dev/null || true
    sleep 1
    
    cd "$DAEMON_DIR" && nohup node daemon.js > daemon.log 2>&1 &
    cd "$INSTALL_DIR" && PORT=6767 nohup node server.js > panel.log 2>&1 &
    
    echo "✅ Installation Complete!"
    echo "🔑 Default Admin: username 'admin', password 'admin123'"
    echo "🌐 Access Panel at: http://localhost:6767"
}

do_update() {
    echo "🔄 Updating KyraPanel (Preserving Database)..."
    pkill -f "node.*server.js" 2>/dev/null || true
    pkill -f "node.*daemon.js" 2>/dev/null || true
    sleep 1
    do_install
    echo "✅ Update Complete!"
}

do_uninstall() {
    echo "🗑️ Uninstalling KyraPanel..."
    pkill -f "node.*server.js" 2>/dev/null || true
    pkill -f "node.*daemon.js" 2>/dev/null || true
    rm -rf "$INSTALL_DIR" "$DAEMON_DIR"
    echo "✅ Uninstalled successfully."
}

do_install_cf() {
    echo "☁️ Installing Cloudflared..."
    curl -L --output cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
    chmod +x cloudflared
    sudo mv cloudflared /usr/local/bin/ 2>/dev/null || mv cloudflared ~/bin/ 2>/dev/null || echo "⚠️ Moved to current directory. Add to PATH manually."
    echo "✅ Cloudflared installed!"
    echo "💡 Run this to expose your panel: cloudflared tunnel --url http://localhost:6767"
}

do_uninstall_cf() {
    echo "🗑️ Uninstalling Cloudflared..."
    sudo rm -f /usr/local/bin/cloudflared 2>/dev/null || rm -f ~/bin/cloudflared 2>/dev/null || rm -f ./cloudflared 2>/dev/null
    echo "✅ Cloudflared uninstalled."
}

# ==========================================
# TUI MENU LOOP
# ==========================================
while true; do
    clear
    echo "========================================================"
    echo "           🐉 KyraPanel Unified Manager 🐉              "
    echo "========================================================"
    echo "  1) Install KyraPanel (Full Setup with Auth & Roles)"
    echo "  2) Update KyraPanel (Safe, preserves database)"
    echo "  3) Uninstall KyraPanel (Removes files)"
    echo "  4) Install Cloudflared (For domain tunneling)"
    echo "  5) Uninstall Cloudflared"
    echo "  6) Exit"
    echo "========================================================"
    echo -n "Select an option [1-6]: "
    read choice

    case $choice in
        1) do_install; read -p "Press Enter to return to menu..." ;;
        2) do_update; read -p "Press Enter to return to menu..." ;;
        3) do_uninstall; read -p "Press Enter to return to menu..." ;;
        4) do_install_cf; read -p "Press Enter to return to menu..." ;;
        5) do_uninstall_cf; read -p "Press Enter to return to menu..." ;;
        6) echo "Goodbye!"; exit 0 ;;
        *) echo "Invalid option."; sleep 1 ;;
    esac
done
