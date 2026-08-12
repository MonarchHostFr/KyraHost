#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then 
    echo "❌ Please run as root (sudo su)"
    exit 1
fi

echo "========================================================="
echo "  🐉 KyraPanel Complete Auto-Installer"
echo "  Panel: Port 6767 | Daemon: Port 6868"
echo "========================================================="

# 1. Install Docker
if ! command -v docker &> /dev/null; then
    echo "🐳 Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker && systemctl start docker
    echo "✅ Docker installed successfully"
else
    echo "✅ Docker already installed"
fi

# 2. Install Node.js 20 & PM2
if ! command -v node &> /dev/null; then
    echo "🟢 Installing Node.js 20..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt install -y nodejs
    echo "✅ Node.js installed successfully"
else
    echo "✅ Node.js already installed"
fi

npm install -g pm2
echo "✅ PM2 installed"

# 3. Setup KyraPanel (Port 6767)
echo "📦 Setting up KyraPanel..."
mkdir -p /var/www/kyrapanel/public /var/www/kyrapanel/database
cd /var/www/kyrapanel

cat > package.json << 'PKG'
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
const PORT = 6767;

app.use(cors());
app.use(bodyParser.json());
app.use(express.static(path.join(__dirname, "public")));

const db = new sqlite3.Database("./database/kyrapanel.db");
db.serialize(() => {
  db.run(`CREATE TABLE IF NOT EXISTS eggs (
    id TEXT PRIMARY KEY,
    name TEXT,
    docker_image TEXT,
    startup_cmd TEXT,
    variables TEXT
  )`);
  db.run(`CREATE TABLE IF NOT EXISTS servers (
    id TEXT PRIMARY KEY,
    name TEXT,
    egg_id TEXT,
    status TEXT,
    port INTEGER,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  )`);
});

app.get("/api/eggs", (req, res) => {
  db.all("SELECT * FROM eggs", [], (err, rows) => {
    res.json(err ? [] : rows);
  });
});

app.post("/api/eggs", (req, res) => {
  const { name, docker_image, startup_cmd, variables } = req.body;
  const id = uuidv4();
  db.run(`INSERT INTO eggs VALUES (?, ?, ?, ?, ?)`, 
    [id, name, docker_image, startup_cmd, JSON.stringify(variables || [])], 
    function(err) { 
      res.json(err ? {error:err.message} : {success:true, id:id}); 
    });
});

app.delete("/api/eggs/:id", (req, res) => {
  db.run(`DELETE FROM eggs WHERE id = ?`, [req.params.id], (err) => {
    res.json(err ? {error:err.message} : {success:true});
  });
});

app.get("/api/servers", (req, res) => {
  db.all("SELECT * FROM servers ORDER BY created_at DESC", [], (err, rows) => {
    res.json(err ? [] : rows);
  });
});

app.post("/api/servers", (req, res) => {
  const { name, egg_id, port } = req.body;
  const id = uuidv4();
  
  db.run(`INSERT INTO servers (id, name, egg_id, status, port) VALUES (?, ?, ?, 'installing', ?)`, 
    [id, name, egg_id, port], function(err) {
      if(err) return res.status(500).json({error:err.message});
      
      db.get(`SELECT * FROM eggs WHERE id = ?`, [egg_id], (err, egg) => {
        if(!egg) {
          db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
          return res.json({success:true, server_id:id, warning:'Egg not found'});
        }
        
        const postData = JSON.stringify({ 
          name: `kyra_${id.substring(0,8)}`, 
          image: egg.docker_image, 
          port: port, 
          startup: egg.startup_cmd, 
          env: [] 
        });
        
        const options = { 
          hostname: 'localhost', 
          port: 6868, 
          path: '/create', 
          method: 'POST', 
          headers: { 
            'Content-Type': 'application/json', 
            'Content-Length': Buffer.byteLength(postData) 
          } 
        };
        
        const reqDaemon = http.request(options, (resD) => {
          let data = ''; 
          resD.on('data', c => data+=c); 
          resD.on('end', () => {
            try {
              const result = JSON.parse(data);
              if(result.success) {
                db.run(`UPDATE servers SET status = 'online' WHERE id = ?`, [id]);
                res.json({ success: true, server_id: id, daemon: result });
              } else {
                db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
                res.json({ success: false, error: result.error });
              }
            } catch(e) {
              db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]);
              res.json({ success: false, error: 'Invalid daemon response' });
            }
          });
        });
        
        reqDaemon.on('error', (e) => { 
          db.run(`UPDATE servers SET status = 'error' WHERE id = ?`, [id]); 
          res.json({success:false, error:'Daemon unreachable: ' + e.message}); 
        });
        
        reqDaemon.write(postData); 
        reqDaemon.end();
      });
    });
});

app.delete("/api/servers/:id", (req, res) => {
  db.get(`SELECT * FROM servers WHERE id = ?`, [req.params.id], (err, server) => {
    if(err || !server) return res.status(404).json({error:'Server not found'});
    
    const postData = JSON.stringify({ name: `kyra_${req.params.id.substring(0,8)}` });
    const options = { 
      hostname: 'localhost', port: 6868, path: '/delete', method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(postData) }
    };
    
    const reqDaemon = http.request(options, (resD) => {
      let data = ''; 
      resD.on('data', c => data+=c); 
      resD.on('end', () => {
        db.run(`DELETE FROM servers WHERE id = ?`, [req.params.id]);
        res.json({success:true});
      });
    });
    
    reqDaemon.on('error', () => {
      db.run(`DELETE FROM servers WHERE id = ?`, [req.params.id]);
      res.json({success:true, warning:'Server deleted from DB but daemon unreachable'});
    });
    
    reqDaemon.write(postData);
    reqDaemon.end();
  });
});

app.get("/api/node-status", (req, res) => {
  http.get('http://localhost:6868/system', (r) => { 
    let d=''; 
    r.on('data',c=>d+=c); 
    r.on('end',()=> {
      try { res.json(JSON.parse(d)); } 
      catch(e) { res.json({status:'offline'}); }
    });
  }).on('error', () => res.json({status:'offline'}));
});

app.get("/", (req, res) => res.sendFile(path.join(__dirname, "public", "index.html")));
app.get("/eggs", (req, res) => res.sendFile(path.join(__dirname, "public", "eggs.html")));
app.get("/servers", (req, res) => res.sendFile(path.join(__dirname, "public", "servers.html")));

app.listen(PORT, '0.0.0.0', () => console.log(`✅ KyraPanel running on http://0.0.0.0:${PORT}`));
SRV

# 4. Setup KyraDaemon (Port 6868)
echo "🤖 Setting up KyraDaemon..."
mkdir -p /var/www/kyradaemon
cd /var/www/kyradaemon

cat > package.json << 'DPKG'
{
  "name": "kyradaemon",
  "version": "1.0.0",
  "main": "daemon.js",
  "dependencies": {
    "express": "^4.18.2",
    "dockerode": "^4.0.0"
  }
}
DPKG

cat > daemon.js << 'DMN'
const express = require('express');
const Docker = require('dockerode');
const app = express();
app.use(express.json());
const docker = new Docker();

app.get('/system', async (req, res) => {
  try { 
    const info = await docker.info(); 
    res.json({ 
      status: 'online', 
      memory: Math.round(info.MemTotal / 1024 / 1024 / 1024) + 'GB',
      containers: info.Containers,
      running: info.ContainersRunning
    }); 
  } catch(e) { 
    res.status(500).json({error: e.message}); 
  }
});

app.post('/create', async (req, res) => {
  const { name, image, port, startup, env } = req.body;
  try {
    console.log(`📦 Pulling ${image}...`);
    const stream = await docker.pull(image);
    await new Promise((resolve, reject) => 
      docker.modem.followProgress(stream, (err, out) => err ? reject(err) : resolve(out))
    );
    
    console.log(`🚀 Creating container ${name} on port ${port}...`);
    const container = await docker.createContainer({
      Image: image, 
      name: name,
      ExposedPorts: { 
        [`${port}/tcp`]: {}, 
        [`${port}/udp`]: {} 
      },
      HostConfig: { 
        PortBindings: { 
          [`${port}/tcp`]: [{ HostPort: port.toString() }], 
          [`${port}/udp`]: [{ HostPort: port.toString() }] 
        }, 
        RestartPolicy: { Name: 'always' } 
      },
      Env: env || [], 
      Cmd: startup ? startup.split(' ') : undefined
    });
    
    await container.start();
    console.log(`✅ Container ${name} started successfully`);
    res.json({ success: true, id: container.id });
  } catch(e) { 
    console.error(`❌ Error: ${e.message}`);
    res.status(500).json({error: e.message}); 
  }
});

app.post('/delete', async (req, res) => {
  const { name } = req.body;
  try {
    const container = docker.getContainer(name);
    await container.stop();
    await container.remove();
    console.log(`🗑️ Container ${name} deleted`);
    res.json({ success: true });
  } catch(e) { 
    res.status(500).json({error: e.message}); 
  }
});

app.listen(6868, '0.0.0.0', () => console.log('🚀 KyraDaemon running on port 6868'));
DMN

# 5. Create Frontend UI - Dashboard
cat > /var/www/kyrapanel/public/index.html << 'HTML1'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KyraPanel - Dashboard</title>
    <script src="https://cdn.tailwindcss.com"></script>
    <style>
        .loading { animation: pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite; }
        @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: .5; } }
    </style>
</head>
<body class="bg-gray-900 text-white font-sans">
    <nav class="bg-gray-800 p-4 shadow-lg">
        <div class="container mx-auto flex justify-between items-center">
            <h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1>
            <div class="space-x-4">
                <a href="/" class="hover:text-blue-400 font-bold">Dashboard</a>
                <a href="/servers" class="hover:text-blue-400">Servers</a>
                <a href="/eggs" class="hover:text-blue-400">Egg Manager</a>
            </div>
        </div>
    </nav>

    <main class="container mx-auto mt-10 p-4">
        <div class="grid grid-cols-1 md:grid-cols-3 gap-6 mb-8">
            <div class="bg-gray-800 p-6 rounded-lg shadow">
                <h2 class="text-xl font-semibold mb-2">Total Servers</h2>
                <p class="text-4xl font-bold text-blue-400" id="server-count">0</p>
            </div>
            <div class="bg-gray-800 p-6 rounded-lg shadow">
                <h2 class="text-xl font-semibold mb-2">Daemon Status</h2>
                <p class="text-4xl font-bold text-yellow-400 loading" id="node-status">Checking...</p>
            </div>
            <div class="bg-gray-800 p-6 rounded-lg shadow">
                <h2 class="text-xl font-semibold mb-2">System</h2>
                <p class="text-4xl font-bold text-green-400">Online</p>
            </div>
        </div>

        <div class="bg-gray-800 p-6 rounded-lg shadow">
            <h2 class="text-2xl font-bold mb-4">Deploy New Server</h2>
            <form id="server-form" class="space-y-4">
                <input type="text" id="server-name" placeholder="Server Name" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-blue-500 outline-none" required>
                <input type="number" id="server-port" placeholder="Port (e.g., 25565)" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-blue-500 outline-none" required>
                <select id="server-egg" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-blue-500 outline-none">
                    <option value="">Select an Egg...</option>
                </select>
                <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white font-bold py-3 px-6 rounded transition">Create & Start Server</button>
            </form>
        </div>
    </main>

    <script>
        async function init() {
            const eggs = await (await fetch('/api/eggs')).json();
            const sel = document.getElementById('server-egg');
            sel.innerHTML = '<option value="">Select an Egg...</option>' + 
                eggs.map(e => `<option value="${e.id}">${e.name}</option>`).join('');
            
            const servers = await (await fetch('/api/servers')).json();
            document.getElementById('server-count').innerText = servers.length;
            
            const status = await (await fetch('/api/node-status')).json();
            const el = document.getElementById('node-status');
            el.innerText = status.status === 'online' ? 'Online ✓' : 'Offline ✗';
            el.className = status.status === 'online' ? 'text-4xl font-bold text-green-400' : 'text-4xl font-bold text-red-400';
        }
        
        init();
        
        document.getElementById('server-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const btn = e.target.querySelector('button');
            btn.innerText = 'Creating...';
            btn.disabled = true;
            
            try {
                const res = await fetch('/api/servers', { 
                    method:'POST', 
                    headers:{'Content-Type':'application/json'}, 
                    body: JSON.stringify({ 
                        name: document.getElementById('server-name').value, 
                        egg_id: document.getElementById('server-egg').value, 
                        port: document.getElementById('server-port').value 
                    }) 
                });
                const data = await res.json();
                
                if(data.success) {
                    alert('✅ Server Created Successfully!\nID: ' + data.server_id);
                    window.location.reload();
                } else {
                    alert('❌ Error: ' + (data.error || 'Unknown error'));
                }
            } catch(err) {
                alert('❌ Error: ' + err.message);
            }
            
            btn.innerText = 'Create & Start Server';
            btn.disabled = false;
        });
    </script>
</body>
</html>
HTML1

# 6. Create Egg Manager UI
cat > /var/www/kyrapanel/public/eggs.html << 'HTML2'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KyraPanel - Egg Manager</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-900 text-white font-sans">
    <nav class="bg-gray-800 p-4 shadow-lg">
        <div class="container mx-auto flex justify-between items-center">
            <h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1>
            <div class="space-x-4">
                <a href="/" class="hover:text-blue-400">Dashboard</a>
                <a href="/servers" class="hover:text-blue-400">Servers</a>
                <a href="/eggs" class="hover:text-blue-400 font-bold">Egg Manager</a>
            </div>
        </div>
    </nav>

    <main class="container mx-auto mt-10 p-4 max-w-5xl">
        <div class="bg-gray-800 p-6 rounded-lg shadow mb-8">
            <h2 class="text-2xl font-bold mb-4">Import Pterodactyl Egg</h2>
            <form id="egg-form" class="space-y-4">
                <input type="text" id="egg-name" placeholder="Egg Name (e.g., Minecraft Paper)" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-green-500 outline-none" required>
                <input type="text" id="docker-image" placeholder="Docker Image (e.g., ghcr.io/pterodactyl/yolks:java_17)" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-green-500 outline-none" required>
                <input type="text" id="startup-cmd" placeholder="Startup Command (e.g., java -Xms128M -jar server.jar)" class="w-full p-3 rounded bg-gray-700 border border-gray-600 focus:border-green-500 outline-none" required>
                <button type="submit" class="bg-green-600 hover:bg-green-700 text-white font-bold py-3 px-6 rounded transition">Import Egg</button>
            </form>
        </div>

        <div class="bg-gray-800 p-6 rounded-lg shadow">
            <h2 class="text-2xl font-bold mb-4">Saved Eggs</h2>
            <div id="egg-list" class="space-y-3">
                <p class="text-gray-400">Loading...</p>
            </div>
        </div>
    </main>

    <script>
        async function loadEggs() {
            const eggs = await (await fetch('/api/eggs')).json();
            const list = document.getElementById('egg-list');
            
            if(eggs.length === 0) {
                list.innerHTML = '<p class="text-gray-400">No eggs found. Import one above!</p>';
                return;
            }
            
            list.innerHTML = eggs.map(e => `
                <div class="bg-gray-700 p-4 rounded flex justify-between items-center">
                    <div>
                        <h3 class="font-bold text-lg">${e.name}</h3>
                        <p class="text-sm text-gray-400">${e.docker_image}</p>
                    </div>
                    <button onclick="deleteEgg('${e.id}')" class="bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded transition">Delete</button>
                </div>
            `).join('');
        }
        
        async function deleteEgg(id) {
            if(!confirm('Are you sure you want to delete this egg?')) return;
            await fetch(`/api/eggs/${id}`, { method: 'DELETE' });
            loadEggs();
        }
        
        document.getElementById('egg-form').addEventListener('submit', async (e) => {
            e.preventDefault();
            const res = await fetch('/api/eggs', { 
                method:'POST', 
                headers:{'Content-Type':'application/json'}, 
                body: JSON.stringify({ 
                    name: document.getElementById('egg-name').value, 
                    docker_image: document.getElementById('docker-image').value, 
                    startup_cmd: document.getElementById('startup-cmd').value 
                }) 
            });
            
            if((await res.json()).success) { 
                alert('✅ Egg Imported Successfully!'); 
                loadEggs();
                e.target.reset();
            }
        });
        
        loadEggs();
    </script>
</body>
</html>
HTML2

# 7. Create Servers List UI
cat > /var/www/kyrapanel/public/servers.html << 'HTML3'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>KyraPanel - Servers</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-900 text-white font-sans">
    <nav class="bg-gray-800 p-4 shadow-lg">
        <div class="container mx-auto flex justify-between items-center">
            <h1 class="text-2xl font-bold text-blue-400">🐉 KyraPanel</h1>
            <div class="space-x-4">
                <a href="/" class="hover:text-blue-400">Dashboard</a>
                <a href="/servers" class="hover:text-blue-400 font-bold">Servers</a>
                <a href="/eggs" class="hover:text-blue-400">Egg Manager</a>
            </div>
        </div>
    </nav>

    <main class="container mx-auto mt-10 p-4">
        <div class="bg-gray-800 p-6 rounded-lg shadow">
            <h2 class="text-2xl font-bold mb-4">All Servers</h2>
            <div id="server-list" class="space-y-3">
                <p class="text-gray-400">Loading...</p>
            </div>
        </div>
    </main>

    <script>
        async function loadServers() {
            const servers = await (await fetch('/api/servers')).json();
            const list = document.getElementById('server-list');
            
            if(servers.length === 0) {
                list.innerHTML = '<p class="text-gray-400">No servers found. Create one from the Dashboard!</p>';
                return;
            }
            
            list.innerHTML = servers.map(s => {
                const statusColor = s.status === 'online' ? 'text-green-400' : s.status === 'error' ? 'text-red-400' : 'text-yellow-400';
                return `
                    <div class="bg-gray-700 p-4 rounded flex justify-between items-center">
                        <div>
                            <h3 class="font-bold text-lg">${s.name}</h3>
                            <p class="text-sm text-gray-400">Port: ${s.port} | Status: <span class="${statusColor}">${s.status}</span></p>
                            <p class="text-xs text-gray-500">ID: ${s.id}</p>
                        </div>
                        <button onclick="deleteServer('${s.id}')" class="bg-red-600 hover:bg-red-700 text-white px-4 py-2 rounded transition">Delete</button>
                    </div>
                `;
            }).join('');
        }
        
        async function deleteServer(id) {
            if(!confirm('Are you sure you want to delete this server? This will stop and remove the container.')) return;
            await fetch(`/api/servers/${id}`, { method: 'DELETE' });
            loadServers();
        }
        
        loadServers();
    </script>
</body>
</html>
HTML3

# 8. Install Dependencies & Start Services
echo "📦 Installing NPM packages (This may take 2-3 minutes)..."
cd /var/www/kyrapanel && npm install --production
cd /var/www/kyradaemon && npm install --production

echo "⚙️ Starting services with PM2..."
pm2 delete kyrapanel kyradaemon 2>/dev/null || true
pm2 start /var/www/kyrapanel/server.js --name kyrapanel
pm2 start /var/www/kyradaemon/daemon.js --name kyradaemon
pm2 save
pm2 startup

VPS_IP=$(curl -s ifconfig.me)
echo "========================================================="
echo "✅ KYRAPANEL & KYRADAEMON INSTALLATION SUCCESSFUL!"
echo "========================================================="
echo "🌐 Panel URL:  http://$VPS_IP:6767"
echo "🤖 Daemon URL: http://$VPS_IP:6868"
echo "========================================================="
echo "💡 Useful Commands:"
echo "   View Panel Logs: pm2 logs kyrapanel"
echo "   View Daemon Logs: pm2 logs kyradaemon"
echo "   Restart Panel: pm2 restart kyrapanel"
echo "   Restart Daemon: pm2 restart kyradaemon"
echo "========================================================="
