const express = require('express');
const path = require('path');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');
const cors = require('cors');

const app = express();
const PORT = process.env.PORT || 3001;

// Security middleware
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      styleSrc: ["'self'", "'unsafe-inline'"],
      scriptSrc: ["'self'", "'unsafe-inline'"],
      imgSrc: ["'self'", "data:", "https://grafana.com"],
      connectSrc: ["'self'", "https://api.monitoring.local"]
    }
  }
}));

app.use(compression());
app.use(cors({
  origin: process.env.NODE_ENV === 'production' 
    ? ['https://yourdomain.com'] 
    : ['http://localhost:3000'],
  credentials: true
}));

app.use(morgan('combined'));
app.use(express.json());
app.use(express.static(path.join(__dirname, 'public')));

// Health check endpoint
app.get('/health', (req, res) => {
  res.status(200).json({
    status: 'healthy',
    timestamp: new Date().toISOString(),
    uptime: process.uptime(),
    services: {
      database: 'connected',
      redis: 'connected',
      prometheus: 'reachable'
    }
  });
});

// API routes
app.get('/api/metrics/summary', async (req, res) => {
  try {
    const summary = {
      totalServers: 142,
      totalContainers: 567,
      uptime: 99.97,
      alerts: {
        critical: 3,
        warning: 12,
        info: 45
      },
      resources: {
        cpu: 67.3,
        memory: 78.2,
        storage: 54.8
      }
    };
    res.json(summary);
  } catch (error) {
    res.status(500).json({ error: 'Failed to fetch metrics' });
  }
});

app.get('/api/alerts/recent', async (req, res) => {
  const alerts = [
    {
      id: 1,
      severity: 'critical',
      message: 'Production Database CPU at 95% for 5 minutes',
      timestamp: new Date(Date.now() - 300000).toISOString(),
      server: 'db-prod-01',
      acknowledged: false
    },
    {
      id: 2,
      severity: 'warning',
      message: 'High memory usage on web-server-03',
      timestamp: new Date(Date.now() - 600000).toISOString(),
      server: 'web-server-03',
      acknowledged: true
    }
  ];
  res.json(alerts);
});

// Serve main application
app.get('*', (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

app.listen(PORT, () => {
  console.log(`Dashboard server running on port ${PORT}`);
});
