CREATE TABLE IF NOT EXISTS device_telemetry (
  id BIGSERIAL PRIMARY KEY,
  device_id VARCHAR(64) NOT NULL,
  temperature_c REAL,
  humidity_pct REAL,
  soil_moisture INTEGER,
  event_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS device_telemetry_device_event_idx
  ON device_telemetry (device_id, event_at DESC);
CREATE TABLE IF NOT EXISTS work_orders (
  id BIGSERIAL PRIMARY KEY,
  asset_tag VARCHAR(32) NOT NULL,
  title VARCHAR(160) NOT NULL,
  priority VARCHAR(10) NOT NULL CHECK (priority IN ('low','medium','high','critical')),
  status VARCHAR(16) NOT NULL DEFAULT 'open' CHECK (status IN ('open','acknowledged','closed')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS work_orders_status_created_idx
  ON work_orders (status, created_at DESC);

CREATE TABLE IF NOT EXISTS inspection_records (
  record_id UUID PRIMARY KEY,
  form_id VARCHAR(48) NOT NULL,
  asset_tag VARCHAR(32) NOT NULL,
  answers JSONB NOT NULL,
  captured_at TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS inspection_records_asset_captured_idx
  ON inspection_records (asset_tag, captured_at DESC);
