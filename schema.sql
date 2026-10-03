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