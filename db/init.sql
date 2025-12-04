-- Create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Create enum types
CREATE TYPE alert_severity AS ENUM ('critical', 'warning', 'info');
CREATE TYPE server_status AS ENUM ('online', 'offline', 'maintenance', 'degraded');
CREATE TYPE user_role AS ENUM ('admin', 'operator', 'viewer');

-- Servers table
CREATE TABLE servers (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4() UNIQUE,
    name VARCHAR(100) NOT NULL,
    hostname VARCHAR(255) NOT NULL UNIQUE,
    ip_address INET NOT NULL,
    status server_status DEFAULT 'online',
    os VARCHAR(50),
    cpu_cores INTEGER,
    memory_gb INTEGER,
    storage_gb INTEGER,
    location VARCHAR(100),
    department VARCHAR(100),
    last_checked TIMESTAMP WITH TIME ZONE,
    last_restart TIMESTAMP WITH TIME ZONE,
    restart_requested_by INTEGER,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Containers table
CREATE TABLE containers (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4() UNIQUE,
    name VARCHAR(255) NOT NULL,
    container_id VARCHAR(64) UNIQUE,
    image VARCHAR(255) NOT NULL,
    status VARCHAR(50),
    server_id INTEGER REFERENCES servers(id),
    cpu_limit DECIMAL(5,2),
    memory_limit_mb INTEGER,
    port_mappings JSONB,
    environment_variables JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Server metrics table
CREATE TABLE server_metrics (
    id SERIAL PRIMARY KEY,
    server_id INTEGER REFERENCES servers(id),
    cpu_usage DECIMAL(5,2) CHECK (cpu_usage >= 0 AND cpu_usage <= 100),
    memory_usage DECIMAL(5,2) CHECK (memory_usage >= 0 AND memory_usage <= 100),
    disk_usage DECIMAL(5,2) CHECK (disk_usage >= 0 AND disk_usage <= 100),
    network_in_bytes BIGINT,
    network_out_bytes BIGINT,
    disk_read_bytes BIGINT,
    disk_write_bytes BIGINT,
    uptime_seconds BIGINT,
    process_count INTEGER,
    load_avg_1m DECIMAL(5,2),
    load_avg_5m DECIMAL(5,2),
    load_avg_15m DECIMAL(5,2),
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Alerts table
CREATE TABLE alerts (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4() UNIQUE,
    server_id INTEGER REFERENCES servers(id),
    container_id INTEGER REFERENCES containers(id),
    severity alert_severity NOT NULL,
    source VARCHAR(100),
    message TEXT NOT NULL,
    details JSONB,
    acknowledged BOOLEAN DEFAULT FALSE,
    acknowledged_by INTEGER,
    acknowledged_at TIMESTAMP WITH TIME ZONE,
    resolved BOOLEAN DEFAULT FALSE,
    resolved_by INTEGER,
    resolved_at TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Users table
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4() UNIQUE,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(255) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role user_role DEFAULT 'viewer',
    full_name VARCHAR(100),
    department VARCHAR(100),
    last_login TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Audit log table
CREATE TABLE audit_logs (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id),
    action VARCHAR(100) NOT NULL,
    resource_type VARCHAR(50),
    resource_id INTEGER,
    details JSONB,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Maintenance schedules
CREATE TABLE maintenance_schedules (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4() UNIQUE,
    title VARCHAR(255) NOT NULL,
    description TEXT,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE NOT NULL,
    affected_servers JSONB,
    status VARCHAR(50) DEFAULT 'scheduled',
    created_by INTEGER REFERENCES users(id),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Backups table
CREATE TABLE backups (
    id SERIAL PRIMARY KEY,
    uuid UUID DEFAULT uuid_generate_v4() UNIQUE,
    server_id INTEGER REFERENCES servers(id),
    type VARCHAR(50) NOT NULL,
    size_bytes BIGINT,
    location VARCHAR(500),
    status VARCHAR(50) DEFAULT 'pending',
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    created_by INTEGER REFERENCES users(id)
);

-- Create indexes for performance
CREATE INDEX idx_server_metrics_timestamp ON server_metrics(timestamp DESC);
CREATE INDEX idx_server_metrics_server_id ON server_metrics(server_id);
CREATE INDEX idx_alerts_created_at ON alerts(created_at DESC);
CREATE INDEX idx_alerts_severity ON alerts(severity);
CREATE INDEX idx_alerts_acknowledged ON alerts(acknowledged) WHERE acknowledged = FALSE;
CREATE INDEX idx_containers_server_id ON containers(server_id);
CREATE INDEX idx_audit_logs_created_at ON audit_logs(created_at DESC);
CREATE INDEX idx_audit_logs_user_id ON audit_logs(user_id);

-- Create function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for updated_at
CREATE TRIGGER update_servers_updated_at BEFORE UPDATE ON servers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_containers_updated_at BEFORE UPDATE ON containers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_alerts_updated_at BEFORE UPDATE ON alerts
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_users_updated_at BEFORE UPDATE ON users
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Create function for alert aggregation
CREATE OR REPLACE FUNCTION get_alert_summary()
RETURNS TABLE (
    critical_count BIGINT,
    warning_count BIGINT,
    info_count BIGINT,
    total_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        COUNT(*) FILTER (WHERE severity = 'critical' AND acknowledged = FALSE) as critical_count,
        COUNT(*) FILTER (WHERE severity = 'warning' AND acknowledged = FALSE) as warning_count,
        COUNT(*) FILTER (WHERE severity = 'info' AND acknowledged = FALSE) as info_count,
        COUNT(*) FILTER (WHERE acknowledged = FALSE) as total_count
    FROM alerts;
END;
$$ LANGUAGE plpgsql;

-- Create function for server statistics
CREATE OR REPLACE FUNCTION get_server_statistics()
RETURNS TABLE (
    total_servers BIGINT,
    online_servers BIGINT,
    offline_servers BIGINT,
    avg_cpu_usage DECIMAL,
    avg_memory_usage DECIMAL
) AS $$
BEGIN
    RETURN QUERY
    WITH latest_metrics AS (
        SELECT DISTINCT ON (server_id) *
        FROM server_metrics
        ORDER BY server_id, timestamp DESC
    )
    SELECT
        COUNT(*) as total_servers,
        COUNT(*) FILTER (WHERE status = 'online') as online_servers,
        COUNT(*) FILTER (WHERE status = 'offline') as offline_servers,
        AVG(cpu_usage) as avg_cpu_usage,
        AVG(memory_usage) as avg_memory_usage
    FROM servers s
    LEFT JOIN latest_metrics lm ON s.id = lm.server_id;
END;
$$ LANGUAGE plpgsql;

-- Insert default admin user (password: Admin123!)
INSERT INTO users (username, email, password_hash, role, full_name, is_active)
VALUES (
    'admin',
    'admin@monitoring.local',
    crypt('Admin123!', gen_salt('bf')),
    'admin',
    'System Administrator',
    TRUE
) ON CONFLICT (username) DO NOTHING;

-- Insert sample data
INSERT INTO servers (name, hostname, ip_address, status, os, cpu_cores, memory_gb, storage_gb, location, department)
VALUES
    ('Production DB 01', 'db-prod-01', '10.0.1.10', 'online', 'Ubuntu 22.04', 8, 32, 500, 'Data Center A', 'Database'),
    ('Web Server 01', 'web-01', '10.0.1.20', 'online', 'CentOS 7', 4, 16, 100, 'Data Center A', 'Web Services'),
    ('API Gateway', 'api-gw-01', '10.0.1.30', 'online', 'Ubuntu 20.04', 4, 8, 50, 'Data Center B', 'API Services'),
    ('Redis Cache', 'redis-01', '10.0.1.40', 'online', 'Debian 11', 2, 4, 20, 'Data Center A', 'Caching'),
    ('Monitoring Server', 'mon-01', '10.0.1.50', 'online', 'Ubuntu 22.04', 4, 16, 200, 'Data Center B', 'Monitoring'),
    ('Backup Server', 'backup-01', '10.0.1.60', 'offline', 'Ubuntu 22.04', 2, 8, 2000, 'Data Center A', 'Backup')
ON CONFLICT (hostname) DO NOTHING;

-- Insert sample metrics
DO $$
DECLARE
    server RECORD;
BEGIN
    FOR server IN SELECT id FROM servers LOOP
        INSERT INTO server_metrics (server_id, cpu_usage, memory_usage, disk_usage, network_in_bytes, network_out_bytes, process_count)
        VALUES (
            server.id,
            RANDOM() * 100,
            RANDOM() * 100,
            RANDOM() * 100,
            (RANDOM() * 1000000000)::BIGINT,
            (RANDOM() * 1000000000)::BIGINT,
            (RANDOM() * 1000)::INTEGER
        );
    END LOOP;
END $$;

-- Insert sample alerts
INSERT INTO alerts (server_id, severity, source, message, details)
VALUES
    (1, 'critical', 'prometheus', 'Database CPU usage above 95%', '{"cpu_usage": 96.5, "duration": "5m", "threshold": 90}'::jsonb),
    (2, 'warning', 'node_exporter', 'High memory usage detected', '{"memory_usage": 85.2, "threshold": 80}'::jsonb),
    (6, 'critical', 'ping', 'Server is not responding', '{"last_response": "5 minutes ago"}'::jsonb),
    (3, 'info', 'grafana', 'New user logged in', '{"user": "admin", "ip": "10.0.0.100"}'::jsonb)
ON CONFLICT DO NOTHING;
