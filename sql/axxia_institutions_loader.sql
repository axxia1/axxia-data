-- Loader for Axxia Institutions from CLUES CSV (full)
-- Expects CSV columns: name,type_norm,source_type,city,state,ownership,clues,institution_group,phone1,phone2,rfc,active

BEGIN;

CREATE SCHEMA IF NOT EXISTS axxia;

-- Ensure states catalog exists (should be preloaded)
CREATE TABLE IF NOT EXISTS axxia.cat_states_mx (
  name TEXT PRIMARY KEY
);

-- Relaxed schema to accommodate external catalogs
CREATE TABLE IF NOT EXISTS axxia.cat_institutions_mx (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL,
  type_norm TEXT NULL,              -- normalized type (Hospital, Clínica, etc.)
  source_type TEXT NULL,            -- original 'NOMBRE TIPO ESTABLECIMIENTO'
  city TEXT NOT NULL,
  state TEXT NOT NULL REFERENCES axxia.cat_states_mx(name) ON UPDATE CASCADE ON DELETE RESTRICT,
  ownership TEXT NULL,              -- Público / Privado (heuristics)
  clues TEXT NULL,                  -- official CLUES key (unique per establishment)
  institution_group TEXT NULL,      -- 'NOMBRE DE LA INSTITUCION' (e.g., IMSS, ISSSTE, etc.)
  phone1 TEXT NULL,
  phone2 TEXT NULL,
  rfc TEXT NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(clues)
);

-- Indexes for search
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX IF NOT EXISTS inst_name_trgm_idx ON axxia.cat_institutions_mx USING GIN (name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS inst_state_idx ON axxia.cat_institutions_mx(state);
CREATE INDEX IF NOT EXISTS inst_type_idx ON axxia.cat_institutions_mx(type_norm);

-- Staging table for CSV import
DROP TABLE IF EXISTS axxia._stg_institutions_csv;
CREATE TABLE axxia._stg_institutions_csv(
  name TEXT, type_norm TEXT, source_type TEXT, city TEXT, state TEXT, ownership TEXT,
  clues TEXT, institution_group TEXT, phone1 TEXT, phone2 TEXT, rfc TEXT, active TEXT
);

-- COPY from file path (adjust if running from different working dir)
-- Note: If running in Render or docker, place the CSV inside container path and update the path below.
-- \copy axxia._stg_institutions_csv FROM 'cat_institutions_mx_full.csv' WITH (FORMAT csv, HEADER true, ENCODING 'UTF8');

-- Upsert into main table
INSERT INTO axxia.cat_institutions_mx
(name, type_norm, source_type, city, state, ownership, clues, institution_group, phone1, phone2, rfc, active)
SELECT
  NULLIF(TRIM(name), '') as name,
  NULLIF(TRIM(type_norm), '') as type_norm,
  NULLIF(TRIM(source_type), '') as source_type,
  NULLIF(TRIM(city), '') as city,
  NULLIF(TRIM(state), '') as state,
  NULLIF(TRIM(ownership), '') as ownership,
  NULLIF(TRIM(clues), '') as clues,
  NULLIF(TRIM(institution_group), '') as institution_group,
  NULLIF(TRIM(phone1), '') as phone1,
  NULLIF(TRIM(phone2), '') as phone2,
  NULLIF(TRIM(rfc), '') as rfc,
  CASE WHEN LOWER(active) IN ('t','true','1','yes','y') THEN TRUE ELSE TRUE END  -- default TRUE
FROM axxia._stg_institutions_csv s
ON CONFLICT (clues) DO UPDATE
SET name = EXCLUDED.name,
    type_norm = EXCLUDED.type_norm,
    source_type = EXCLUDED.source_type,
    city = EXCLUDED.city,
    state = EXCLUDED.state,
    ownership = EXCLUDED.ownership,
    institution_group = EXCLUDED.institution_group,
    phone1 = EXCLUDED.phone1,
    phone2 = EXCLUDED.phone2,
    rfc = EXCLUDED.rfc,
    active = EXCLUDED.active;

COMMIT;