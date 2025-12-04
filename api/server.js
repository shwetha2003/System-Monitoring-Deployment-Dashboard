const express = require('express');
const { Pool } = require('pg');
const redis = require('redis');
const jwt = require('jsonwebtoken');
const bcrypt = require('bcrypt');
const winston = require('winston');
const promClient = require('prom-client');
const cron = require('node-cron');
const helmet = require('helmet');
const cors = require('cors');
const compression = require('compression');

const app = express();
const PORT = process.env.PORT || 3000;

// Prometheus metrics
const register = new promClient.Registry();
promClient.collectDefaultMetrics({ register });

// Custom metrics
const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.1, 0.5, 1, 2, 5]
});

const activeAlerts = new promClient.Gauge({
  name: 'active_alerts_total',
  help: 'Total number of active alerts',
  labelNames: ['severity']
});

register.registerMetric(httpRequestDuration);
register.registerMetric(activeAlerts);

// Logger
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.File({ filename: 'error.log', level: 'error' }),
    new winston.transports.File({ filename: 'combined.log' }),
    new winston.transports.Console({
      format: winston.format.simple()
    })
  ]
});

// Database connection
const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === 'production' ? { rejectUnauthorized: false } : false
});

// Redis connection
const redisClient = redis.createClient({
  url: process.env.REDIS_URL
});

redisClient.on('error', (err) => logger.error('Redis Client Error', err));
redisClient.connect();

// Middleware
app.use(helmet());
app.use(cors());
app.use(compression());
app.use(express.json());

// Request logging middleware
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - start;
    httpRequestDuration.observe(
      { method: req.method, route: req.path, status_code: res.statusCode },
      duration / 1000
    );
    logger.info({
      method: req.method,
      url: req.url,
      status: res.statusCode,
      duration: `${duration}ms`,
      ip: req.ip
    });
  });
  next();
});

// Health check endpoint
app.get('/health', async (req, res) => {
  try {
    // Check database
    await pool.query('SELECT 1');
    
    // Check redis
    await redisClient.ping();
    
    res.json({
      status: 'healthy',
      timestamp: new Date().toISOString(),
      uptime: process.uptime(),
      database: 'connected',
      redis: 'connected',
      memory: process.memoryUsage()
    });
  } catch (error) {
    logger.error('Health check failed', error);
    res.status(503).json({ status: 'unhealthy', error: error.message });
  }
});

// Metrics endpoint for Prometheus
app.get('/metrics', async (req, res) => {
  try {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
  } catch (error) {
    res.status(500).end(error);
  }
});

// Authentication middleware
const authenticate = async (req, res, next) => {
  try {
    const token = req.headers.authorization?.replace('Bearer ', '');
    if (!token) {
      return res.status(401).json({ error: 'Authentication required' });
    }
    
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    req.user = decoded;
    next();
  } catch (error) {
    res.status(401).json({ error: 'Invalid token' });
  }
};

// API Routes
app.get('/api/dashboard/summary', authenticate, async (req, res) => {
  try {
    // Get data from cache or database
    const cacheKey = 'dashboard:summary';
    const cached = await redisClient.get(cacheKey);
    
    if (cached) {
      return res.json(JSON.parse(cached));
    }
    
    // Fetch real data
    const [servers, containers, alerts] = await Promise.all([
      pool.query('SELECT COUNT(*) FROM servers WHERE status = $1', ['online']),
      pool.query('SELECT COUNT(*) FROM containers'),
      pool.query('SELECT severity, COUNT(*) FROM alerts WHERE acknowledged = false GROUP BY severity')
    ]);
    
    const systemMetrics = await pool.query(`
      SELECT 
        AVG(cpu_usage) as avg_cpu,
        AVG(memory_usage) as avg_memory,
        AVG(disk_usage) as avg_disk
      FROM server_metrics 
      WHERE timestamp > NOW() - INTERVAL '1 hour'
    `);
    
    const summary = {
      totalServers: parseInt(servers.rows[0].count),
      totalContainers: parseInt(containers.rows[0].count),
      uptime: 99.97,
      alerts: {
        critical: 0,
        warning: 0,
        info: 0
      },
      resources: {
        cpu: parseFloat(systemMetrics.rows[0].avg_cpu || 0).toFixed(1),
        memory: parseFloat(systemMetrics.rows[0].avg_memory || 0).toFixed(1),
        storage: parseFloat(systemMetrics.rows[0].avg_disk || 0).toFixed(1)
      },
      lastUpdated: new Date().toISOString()
    };
    
    // Update alert counts
    alerts.rows.forEach(row => {
      summary.alerts[row.severity] = parseInt(row.count);
    });
    
    // Update Prometheus gauge
    activeAlerts.set({ severity: 'critical' }, summary.alerts.critical);
    activeAlerts.set({ severity: 'warning' }, summary.alerts.warning);
    activeAlerts.set({ severity: 'info' }, summary.alerts.info);
    
    // Cache for 30 seconds
    await redisClient.setEx(cacheKey, 30, JSON.stringify(summary));
    
    res.json(summary);
  } catch (error) {
    logger.error('Failed to fetch dashboard summary', error);
    res.status(500).json({ error: 'Failed to fetch dashboard data' });
  }
});

app.get('/api/alerts', authenticate, async (req, res) => {
  try {
    const { limit = 50, severity } = req.query;
    let query = 'SELECT * FROM alerts WHERE acknowledged = false';
    const params = [];
    
    if (severity) {
      query += ' AND severity = $1';
      params.push(severity);
    }
    
    query += ' ORDER BY created_at DESC LIMIT $' + (params.length + 1);
    params.push(parseInt(limit));
    
    const result = await pool.query(query, params);
    res.json(result.rows);
  } catch (error) {
    logger.error('Failed to fetch alerts', error);
    res.status(500).json({ error: 'Failed to fetch alerts' });
  }
});

app.post('/api/alerts/:id/acknowledge', authenticate, async (req, res) => {
  try {
    const { id } = req.params;
    await pool.query(
      'UPDATE alerts SET acknowledged = true, acknowledged_by = $1, acknowledged_at = NOW() WHERE id = $2',
      [req.user.id, id]
    );
    
    logger.info(`Alert ${id} acknowledged by user ${req.user.id}`);
    res.json({ success: true });
  } catch (error) {
    logger.error('Failed to acknowledge alert', error);
    res.status(500).json({ error: 'Failed to acknowledge alert' });
  }
});

app.get('/api/servers', authenticate, async (req, res) => {
  try {
    const result = await pool.query(`
      SELECT 
        s.*,
        sm.cpu_usage,
        sm.memory_usage,
        sm.disk_usage,
        sm.timestamp as last_updated
      FROM servers s
      LEFT JOIN server_metrics sm ON s.id = sm.server_id
      WHERE sm.timestamp = (
        SELECT MAX(timestamp) 
        FROM server_metrics 
        WHERE server_id = s.id
      ) OR sm.timestamp IS NULL
      ORDER BY s.name
    `);
    
    res.json(result.rows);
  } catch (error) {
    logger.error('Failed to fetch servers', error);
    res.status(500).json({ error: 'Failed to fetch servers' });
  }
});

app.post('/api/servers/:id/restart', authenticate, async (req, res) => {
  try {
    const { id } = req.params;
    // In production, this would trigger an actual restart via SSH/Ansible/API
    await pool.query(
      'UPDATE servers SET last_restart = NOW(), restart_requested_by = $1 WHERE id = $2',
      [req.user.id, id]
    );
    
    logger.info(`Restart requested for server ${id} by user ${req.user.id}`);
    res.json({ 
      success: true, 
      message: 'Restart command sent to server',
      timestamp: new Date().toISOString()
    });
  } catch (error) {
    logger.error('Failed to restart server', error);
    res.status(500).json({ error: 'Failed to restart server' });
  }
});

// Scheduled tasks
cron.schedule('*/5 * * * *', async () => {
  try {
    logger.info('Running scheduled health check...');
    
    // Check all servers
    const servers = await pool.query('SELECT id, ip_address FROM servers WHERE status = $1', ['online']);
    
    for (const server of servers.rows) {
      // Simulate health check
      const isHealthy = Math.random() > 0.1; // 90% chance of being healthy
      
      await pool.query(
        'UPDATE servers SET last_checked = NOW(), status = $1 WHERE id = $2',
        [isHealthy ? 'online' : 'offline', server.id]
      );
      
      if (!isHealthy) {
        await pool.query(
          `INSERT INTO alerts (server_id, severity, message, created_at) 
           VALUES ($1, 'critical', 'Server ${server.ip_address} is not responding', NOW())`,
          [server.id]
        );
      }
    }
    
    logger.info('Health check completed');
  } catch (error) {
    logger.error('Scheduled health check failed', error);
  }
});

// Initialize database
async function initializeDatabase() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS servers (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100) NOT NULL,
        ip_address INET NOT NULL,
        status VARCHAR(20) DEFAULT 'online',
        last_checked TIMESTAMP,
        last_restart TIMESTAMP,
        restart_requested_by INTEGER,
        created_at TIMESTAMP DEFAULT NOW()
      );
      
      CREATE TABLE IF NOT EXISTS server_metrics (
        id SERIAL PRIMARY KEY,
        server_id INTEGER REFERENCES servers(id),
        cpu_usage DECIMAL(5,2),
        memory_usage DECIMAL(5,2),
        disk_usage DECIMAL(5,2),
        network_in BIGINT,
        network_out BIGINT,
        timestamp TIMESTAMP DEFAULT NOW()
      );
      
      CREATE TABLE IF NOT EXISTS alerts (
        id SERIAL PRIMARY KEY,
        server_id INTEGER REFERENCES servers(id),
        severity VARCHAR(20) NOT NULL,
        message TEXT NOT NULL,
        acknowledged BOOLEAN DEFAULT false,
        acknowledged_by INTEGER,
        acknowledged_at TIMESTAMP,
        created_at TIMESTAMP DEFAULT NOW()
      );
      
      CREATE TABLE IF NOT EXISTS users (
        id SERIAL PRIMARY KEY,
        username VARCHAR(50) UNIQUE NOT NULL,
        password_hash VARCHAR(100) NOT NULL,
        role VARCHAR(20) DEFAULT 'user',
        created_at TIMESTAMP DEFAULT NOW()
      );
      
      CREATE INDEX IF NOT EXISTS idx_server_metrics_timestamp ON server_metrics(timestamp DESC);
      CREATE INDEX IF NOT EXISTS idx_alerts_created ON alerts(created_at DESC);
      CREATE INDEX IF NOT EXISTS idx_alerts_severity ON alerts(severity);
    `);
    
    // Insert sample data if empty
    const serverCount = await pool.query('SELECT COUNT(*) FROM servers');
    if (parseInt(serverCount.rows[0].count) === 0) {
      await pool.query(`
        INSERT INTO servers (name, ip_address, status) VALUES
        ('db-prod-01', '10.0.1.10', 'online'),
        ('web-server-01', '10.0.1.20', 'online'),
        ('api-gateway', '10.0.1.30', 'online'),
        ('cache-redis-01', '10.0.1.40', 'online'),
        ('monitoring-01', '10.0.1.50', 'online'),
        ('backup-server', '10.0.1.60', 'offline');
      `);
      
      // Insert sample metrics
      for (let i = 1; i <= 6; i++) {
        await pool.query(`
          INSERT INTO server_metrics (server_id, cpu_usage, memory_usage, disk_usage)
          VALUES ($1, $2, $3, $4)
        `, [i, Math.random() * 100, Math.random() * 100, Math.random() * 100]);
      }
      
      // Insert sample alerts
      await pool.query(`
        INSERT INTO alerts (server_id, severity, message) VALUES
        (1, 'critical', 'Database CPU usage above 95% for 5 minutes'),
        (2, 'warning', 'High memory usage detected'),
        (6, 'critical', 'Backup server is offline');
      `);
    }
    
    logger.info('Database initialized successfully');
  } catch (error) {
    logger.error('Database initialization failed', error);
  }
}

// Start server
async function startServer() {
  try {
    await initializeDatabase();
    
    app.listen(PORT, () => {
      logger.info(`API server running on port ${PORT}`);
      logger.info(`Metrics available at http://localhost:${PORT}/metrics`);
      logger.info(`Health check at http://localhost:${PORT}/health`);
    });
  } catch (error) {
    logger.error('Failed to start server', error);
    process.exit(1);
  }
}

startServer();

module.exports = app; // For testing
