#!/bin/bash

INSTALL_DIR="$HOME/kyrapanel"
DAEMON_DIR="$HOME/kyradaemon"

echo "🚀 KyraPanel Auto-Installer Starting..."

# 1. Ensure Node.js is available
if ! command -v node &> /dev/null; then
    echo "⚠️ Node.js not found. Attempting to install..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || true
    apt-get update && apt-get install -y nodejs || true
fi

if ! command -v node &> /dev/null; then
    echo "❌ CRITICAL: Node.js is still not installed. Please use a Node.js template in CodeSandbox."
    exit 1
fi

echo "✅ Node.js version: $(node -v)"

# 2. Create directories
echo "📁 Creating directories..."
mkdir -p "$INSTALL_DIR/public" "$INSTALL_DIR/database"
mkdir -p "$DAEMON_DIR"

# 3. Write Panel package.json
echo "📝 Writing Panel files..."
cat > "$INSTALL_DIR/package.json" << 'EOF'
{
  "name": "kyrapanel",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.18.2",
    "sqlite3": "^5.1.6",
    "cors": "^2.8.5",
    "body-parser": "^1.20.2",
    "uuid": "^9.0.0"
  }
}
EOF

# 4. Write Panel server.js
cat > "$INSTALL_DIR/server.js" << 'EOF'
const express = require("express");
const sqlite3 = require("sqlite3").verbose();
const cors = require("cors");
const bodyParser = require("body-parser");
const { v4: uuidv4 } = require("uuid");
const path = require("path");
const http = require("http");

const app = express();
const PORT = process.env.PORT || 6767;

app.use(cors());
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, "public")));

const db = new sqlite3.Database("./database/kyrapanel.db");
db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS eggs (id TEXT PRIMARY KEY, name TEXT, docker_image TEXT, startup_cmd TEXT, variables TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS servers (id TEXT PRIMARY KEY, name TEXT, egg_id TEXT, status TEXT, port INTEGER, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`);
});

app.get("/api/eggs", (req, res) => db.all("SELECT * FROM eggs", [], (err, rows) => res.json(err ? [] : rows)));
app.post("/api/eggs", (req, res) => {
  const { name, docker_image, startup_cmd, variables } = req.body;
  const id = uuidv4();
  db.run(`INSERT INTO eggs VALUES (?, ?, ?, ?, ?)`, [id, name, docker_image, startup_cmd, JSON.stringify(variables || [])], function(err) {
    res.json(err ? { error: err.message } : { success: true, id: id });
  });
});
app.delete("/api/eggs/:id", (req, res) => db.run(`DELETE FROM eggs WHERE id = ?`, [req.params.id], (err) => res.json(err ? { error: err.message } : { success: true })));

app.get("/api/servers", (req, res) => db.all("SELECT * FROM servers ORDER BY created_at DESC", [], (err, rows) => res.json(err ? [] : rows)));
app.post("/api/servers", (req, res) => {
  const { name, egg_id, port } = req.body;
  const id = uuidv4();
  db.run(`INSERT INTO servers (id, name, egg_id, status, port) VALUES (?, ?, ?, 'installing', ?)`, [id, name, egg_id, port], function(err) {
    if (err) return res.status(500).json({ error: err.message });
    db.get(`SELECT * FROM eggs WHERE id = ?`, [egg_id], (err, egg) => {
      if (!egg) {
        db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
        return res.json({ success: true, server_id: id, warning: 'Egg not found' });
      }
      const postData = JSON.stringify({ name: `kyra_${id.substring(0, 8)}`, image: egg.docker_image, port: port, startup: egg.startup_cmd, env: [] });
      const options = { hostname: 'localhost', port: 6868, path: '/create', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) } };
      const reqDaemon = http.request(options, (resD) => {
        let data = '';
        resD.on('data', c => data += c);
        resD.on('end', () => {
          try {
            const result = JSON.parse(data);
            if (result.success) {
              db.run(`UPDATE servers SET status = 'online' WHERE id = ?`, [id]);
              res.json({ success: true, server_id: id, daemon: result });
            } else {
              db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
              res.json({ success: false, error: result.error });
            }
          } catch (e) {
            db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
            res.json({ success: false, error: 'Invalid daemon response' });
          }
        });
      });
      reqDaemon.on('error', (e) => {
        db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
        res.json({ success: false, error: 'Daemon unreachable: ' + e.message });
      });
      reqDaemon.write(postData);
      reqDaemon.end();
    });
  });
});
app.delete("/api/servers/:id", (req, res) => {
  db.get(`SELECT * FROM servers WHERE id = ?`, [req.params.id], (err, server) => {
    if (err || !server) return res.status(404).json({ error: 'Server not found' });
    const postData = JSON.stringify({ name: `kyra_${req.params.id.substring(0, 8)}` });
    const options = { hostname: 'localhost', port: 6868, path: '/delete', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) } };
    const reqDaemon = http.request(options, (resD) => {
      let data = '';
      resD.on('data', c => data += c);
      resD.on('end', () => {
        db.run(`DELETE FROM servers WHERE id = ?`, [req.params.id]);
        res.json({ success: true });
      });
    });
    reqDaemon.on('error', () => {
      db.run(`DELETE FROM servers WHERE id = ?`, [req.params.id]);
      res.json({ success: true, warning: 'Server deleted from DB but daemon unreachable' });
    });
    reqDaemon.write(postData);
    reqDaemon.end();
  });
});

app.get("/api/node-status", (req, res) => {
  http.get('http://localhost:6868/system', (r) => {
    let d = '';
    r.on('data', c => d += c);
    r.on('end', () => {
      try { res.json(JSON.parse(d)); } catch (e) { res.json({ status: 'offline' }); }
    });
  }).on('error', () => res.json({ status: 'offline' }));
});

app.get("/", (req, res) => res.sendFile(path.join(__dirname, "public", "index.html")));
app.get("/eggs", (req, res) => res.sendFile(path.join(__dirname, "public", "eggs.html")));
app.get("/servers", (req, res) => res.sendFile(path.join(__dirname, "public", "servers.html")));

app.listen(PORT, '0.0.0.0', () => { console.log(`✅ KyraPanel running on http://0.0.0.0:${PORT}`); });
EOF

# 5. Write Daemon files
echo "📝 Writing Daemon files..."
cat > "$DAEMON_DIR/package.json" << 'EOF'
{
  "name": "kyradaemon",
  "version": "1.0.0",
  "main": "daemon.js",
  "dependencies": {
    "express": "^4.18.2",
    "dockerode": "^4.0.0"
  }
}
EOF

cat > "$DAEMON_DIR/daemon.js" << 'EOF'
const express = require('express');
const app = express();
app.use(express.json());
let mockContainers = [];
const isCodeSandbox = process.env.CODESANDBOX_SBOX_ID !== undefined || process.env.HOME === '/home/coder';
let docker;
if (!isCodeSandbox) {
  try { docker = require('dockerode')(); } catch (e) { isCodeSandbox = true; }
}

app.get('/system', async (req, res) => {
  if (isCodeSandbox) {
    res.json({ status: 'online', memory: '2GB', containers: mockContainers.length, running: mockContainers.filter(c => c.running).length, mock: true });
  } else {
    try {
      const info = await docker.info();
      res.json({ status: 'online', memory: Math.round(info.MemTotal / 1024 / 1024 / 1024) + 'GB', containers: info.Containers, running: info.ContainersRunning });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  }
});

app.post('/create', async (req, res) => {
  const { name, image, port, startup, env } = req.body;
  if (isCodeSandbox) {
    mockContainers.push({ id: 'mock_' + Date.now(), name, image, port, running: true });
    res.json({ success: true, id: 'mock_' + Date.now(), mock: true });
  } else {
    try {
      const stream = await docker.pull(image);
      await new Promise((resolve, reject) => docker.modem.followProgress(stream, (err, out) => err ? reject(err) : resolve(out)));
      const container = await docker.createContainer({
        Image: image, name: name,
        ExposedPorts: { [`${port}/tcp`]: {}, [`${port}/udp`]: {} },
        HostConfig: { PortBindings: { [`${port}/tcp`]: [{ HostPort: port.toString() }], [`${port}/udp`]: [{ HostPort: port.toString() }] }, RestartPolicy: { Name: 'always' } },
        Env: env || [], Cmd: startup ? startup.split(' ') : undefined
      });
      await container.start();
      res.json({ success: true, id: container.id });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  }
});

app.post('/delete', async (req, res) => {
  const { name } = req.body;
  if (isCodeSandbox) {
    mockContainers = mockContainers.filter(c => c.name !== name);
    res.json({ success: true });
  } else {
    try {
      const container = docker.getContainer(name);
      await container.stop();
      await container.remove();
      res.json({ success: true });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  }
});

app.listen(6868, '0.0.0.0', () => console.log('🚀 KyraDaemon running on port 6868'));
EOF

# 6. Write Frontend
echo "📝 Writing Frontend files..."
cat > "$INSTALL_DIR/public/index.html" << 'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>KyraPanel</title><script src="https://cdn.tailwindcss.com"></script></head><body class="bg-gray-900 text-white font-sans"><nav class="bg-gray-800 p-4 shadow-lg"><div class="container mx-auto flex justify-between"><h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1><div class="space-x-4"><a href="/" class="font-bold">Dashboard</a><a href="/servers">Servers</a><a href="/eggs">Egg Manager</a></div></div></nav><main class="container mx-auto mt-10 p-4"><div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8"><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-xl font-semibold mb-2">Total Servers</h2><p class="text-4xl font-bold text-blue-400" id="server-count">0</p></div><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-xl font-semibold mb-2">Daemon Status</h2><p class="text-4xl font-bold text-yellow-400" id="node-status">Checking...</p></div><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-xl font-semibold mb-2">System</h2><p class="text-4xl font-bold text-green-400">Online</p></div></div><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-2xl font-bold mb-4">Deploy New Server</h2><form id="server-form" class="space-y-4"><input type="text" id="server-name" placeholder="Server Name" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required><input type="number" id="server-port" placeholder="Port (e.g., 25565)" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required><select id="server-egg" class="w-full p-3 rounded bg-gray-700 border border-gray-600"><option value="">Select an Egg...</option></select><button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-6 rounded">Create & Start Server</button></form></div></main><script>async function init(){const eggs=await(await fetch('/api/eggs')).json();document.getElementById('server-egg').innerHTML='<option value="">Select an Egg...</option>'+eggs.map(e=>`<option value="${e.id}">${e.name}</option>`).join('');document.getElementById('server-count').innerText=(await(await fetch('/api/servers')).json()).length;const status=await(await fetch('/api/node-status')).json();const el=document.getElementById('node-status');el.innerText=status.status==='online'?'Online ✓'+(status.mock?' (Mock)'):'Offline ✗';el.className=status.status==='online'?'text-4xl font-bold text-green-400':'text-4xl font-bold text-red-400'}init();document.getElementById('server-form').addEventListener('submit',async(e)=>{e.preventDefault();const btn=e.target.querySelector('button');btn.innerText='Creating...';btn.disabled=true;const res=await fetch('/api/servers',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:document.getElementById('server-name').value,egg_id:document.getElementById('server-egg').value,port:document.getElementById('server-port').value})});const data=await res.json();alert(data.success?'✅ Server Created!\nID: '+data.server_id:'❌ Error: '+(data.error||'Unknown'));btn.innerText='Create & Start Server';btn.disabled=false});</script></body></html>
EOF

cat > "$INSTALL_DIR/public/eggs.html" << 'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>KyraPanel - Eggs</title><script src="https://cdn.tailwindcss.com"></script></head><body class="bg-gray-900 text-white font-sans"><nav class="bg-gray-800 p-4 shadow-lg"><div class="container mx-auto flex justify-between"><h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1><div class="space-x-4"><a href="/">Dashboard</a><a href="/servers">Servers</a><a href="/eggs" class="font-bold">Egg Manager</a></div></div></nav><main class="container mx-auto mt-10 p-4 max-w-5xl"><div class="bg-gray-800 p-6 rounded-lg shadow mb-8"><h2 class="text-2xl font-bold mb-4">Import Pterodactyl Egg</h2><form id="egg-form" class="space-y-4"><input type="text" id="egg-name" placeholder="Egg Name" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required><input type="text" id="docker-image" placeholder="Docker Image" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required><input type="text" id="startup-cmd" placeholder="Startup Command" class="w-full p-3 rounded bg-gray-700 border border-gray-600" required><button type="submit" class="bg-green-600 hover:bg-green-700 text-white font-bold py-3 px-6 rounded">Import Egg</button></form></div><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-2xl font-bold mb-4">Saved Eggs</h2><div id="egg-list"><p class="text-gray-400">Loading...</p></div></div></main><script>async function loadEggs(){const eggs=await(await fetch('/api/eggs')).json();document.getElementById('egg-list').innerHTML=eggs.length?eggs.map(e=>`<div class="bg-gray-700 p-4 rounded flex justify-between items-center mb-2"><div><h3 class="font-bold">${e.name}</h3><p class="text-sm text-gray-400">${e.docker_image}</p></div><button onclick="deleteEgg('${e.id}')" class="bg-red-600 px-4 py-2 rounded">Delete</button></div>`).join(''):'<p class="text-gray-400">No eggs found.</p>'}async function deleteEgg(id){if(confirm('Delete this egg?')){await fetch(`/api/eggs/${id}`,{method:'DELETE'});loadEggs()}}document.getElementById('egg-form').addEventListener('submit',async(e)=>{e.preventDefault();const res=await fetch('/api/eggs',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name:document.getElementById('egg-name').value,docker_image:document.getElementById('docker-image').value,startup_cmd:document.getElementById('startup-cmd').value})});if((await res.json()).success){alert('✅ Egg Imported!');loadEggs();e.target.reset()}});loadEggs();</script></body></html>
EOF

cat > "$INSTALL_DIR/public/servers.html" << 'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><title>KyraPanel - Servers</title><script src="https://cdn.tailwindcss.com"></script></head><body class="bg-gray-900 text-white font-sans"><nav class="bg-gray-800 p-4 shadow-lg"><div class="container mx-auto flex justify-between"><h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1><div class="space-x-4"><a href="/">Dashboard</a><a href="/servers" class="font-bold">Servers</a><a href="/eggs">Egg Manager</a></div></div></nav><main class="container mx-auto mt-10 p-4"><div class="bg-gray-800 p-6 rounded-lg shadow"><h2 class="text-2xl font-bold mb-4">All Servers</h2><div id="server-list"><p class="text-gray-400">Loading...</p></div></div></main><script>async function loadServers(){const servers=await(await fetch('/api/servers')).json();document.getElementById('server-list').innerHTML=servers.length?servers.map(s=>`<div class="bg-gray-700 p-4 rounded flex justify-between items-center mb-2"><div><h3 class="font-bold">${s.name}</h3><p class="text-sm text-gray-400">Port: ${s.port} | Status: <span class="${s.status==='online'?'text-green-400':s.status==='error'?'text-red-400':'text-yellow-400'}">${s.status}</span></p></div><button onclick="deleteServer('${s.id}')" class="bg-red-600 px-4 py-2 rounded">Delete</button></div>`).join(''):'<p class="text-gray-400">No servers found.</p>'}async function deleteServer(id){if(confirm('Delete this server?')){await fetch(`/api/servers/${id}`,{method:'DELETE'});loadServers()}}loadServers();</script></body></html>
EOF

# 7. Install NPM
echo "📦 Installing NPM packages (this may take a minute)..."
cd "$INSTALL_DIR" && npm install
cd "$DAEMON_DIR" && npm install

# 8. Start Services
echo "⚙️ Starting services..."
pkill -f "node.*server.js" 2>/dev/null || true
pkill -f "node.*daemon.js" 2>/dev/null || true
sleep 1

cd "$DAEMON_DIR" && nohup node daemon.js > daemon.log 2>&1 &
cd "$INSTALL_DIR" && PORT=6767 nohup node server.js > panel.log 2>&1 &

sleep 3

echo "========================================================="
echo "✅ INSTALLATION COMPLETE!"
echo "📁 Panel: $INSTALL_DIR"
echo "📁 Daemon: $DAEMON_DIR"
echo "🌐 Panel URL: Port 6767"
echo "🤖 Daemon URL: Port 6868"
echo "========================================================="
