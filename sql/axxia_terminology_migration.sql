-- Axxia Terminology Resolver - Migration Script
-- Requires: axxia_schema.sql executed beforehand
-- DB: PostgreSQL 13+

BEGIN;

-- 1) Extensions
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- 2) Columns for popularity and synonyms (idempotent)
ALTER TABLE IF EXISTS axxia.cat_icd10
  ADD COLUMN IF NOT EXISTS popularity INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS synonyms  TEXT[];

ALTER TABLE IF EXISTS axxia.cat_snomed_subset
  ADD COLUMN IF NOT EXISTS popularity INT NOT NULL DEFAULT 0;

ALTER TABLE IF EXISTS axxia.cat_loinc_subset
  ADD COLUMN IF NOT EXISTS popularity INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS synonyms  TEXT[];

ALTER TABLE IF EXISTS axxia.cat_atc_subset
  ADD COLUMN IF NOT EXISTS popularity INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS synonyms  TEXT[];

-- 3) Indexes for speed (idempotent)
-- SNOMED
CREATE INDEX IF NOT EXISTS snomed_fsn_trgm   ON axxia.cat_snomed_subset USING gin (lower(fsn) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS snomed_pop_idx    ON axxia.cat_snomed_subset (popularity DESC);

-- ICD-10
CREATE INDEX IF NOT EXISTS icd_title_trgm    ON axxia.cat_icd10 USING gin (lower(title) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS icd_code_btree    ON axxia.cat_icd10 (code);
CREATE INDEX IF NOT EXISTS icd_pop_idx       ON axxia.cat_icd10 (popularity DESC);

-- LOINC
CREATE INDEX IF NOT EXISTS loinc_comp_trgm   ON axxia.cat_loinc_subset USING gin (lower(component) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS loinc_code_btree  ON axxia.cat_loinc_subset (loinc);
CREATE INDEX IF NOT EXISTS loinc_pop_idx     ON axxia.cat_loinc_subset (popularity DESC);

-- ATC
CREATE INDEX IF NOT EXISTS atc_name_trgm     ON axxia.cat_atc_subset USING gin (lower(name) gin_trgm_ops);
CREATE INDEX IF NOT EXISTS atc_code_btree    ON axxia.cat_atc_subset (atc);
CREATE INDEX IF NOT EXISTS atc_pop_idx       ON axxia.cat_atc_subset (popularity DESC);

-- Helper: array_to_string(synonyms,' ') trigram indexes where synonyms exist
-- ICD
CREATE INDEX IF NOT EXISTS icd_syn_trgm ON axxia.cat_icd10
USING gin (lower(coalesce(array_to_string(synonyms,' '),'')) gin_trgm_ops);
-- LOINC
CREATE INDEX IF NOT EXISTS loinc_syn_trgm ON axxia.cat_loinc_subset
USING gin (lower(coalesce(array_to_string(synonyms,' '),'')) gin_trgm_ops);
-- ATC
CREATE INDEX IF NOT EXISTS atc_syn_trgm ON axxia.cat_atc_subset
USING gin (lower(coalesce(array_to_string(synonyms,' '),'')) gin_trgm_ops);

-- 4) Utility: normalize text
CREATE OR REPLACE FUNCTION axxia._norm_text(t text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT AS $$
  SELECT regexp_replace(lower(trim(t)), '\s+', ' ', 'g');
$$;

-- 5) Resolver functions (returning candidates with score)

-- SNOMED
CREATE OR REPLACE FUNCTION axxia.resolve_snomed(q_in text, lim int DEFAULT 10)
RETURNS TABLE(code text, system text, display text, score numeric, is_exact boolean) 
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT axxia._norm_text(q_in) AS s),
  cand AS (
    SELECT
      concept_id::text AS code,
      'SNOMED'::text   AS system,
      fsn              AS display,
      popularity,
      (CASE WHEN concept_id::text = (SELECT s FROM q) THEN 10 ELSE 0 END) AS score_code_exact,
      GREATEST(similarity(lower(fsn), (SELECT s FROM q)),
               similarity(lower(coalesce(array_to_string(synonyms,' '),'')), (SELECT s FROM q))) AS sim_best
    FROM axxia.cat_snomed_subset
    WHERE concept_id::text = (SELECT s FROM q)
       OR lower(fsn) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(coalesce(array_to_string(synonyms,' '),'')) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(fsn) % (SELECT s FROM q)
       OR lower(coalesce(array_to_string(synonyms,' '),'')) % (SELECT s FROM q)
  )
  SELECT code, system, display,
         ROUND(1.5*score_code_exact + 4.0*sim_best + 0.0005*popularity, 4) AS score,
         (score_code_exact > 0) AS is_exact
  FROM cand
  ORDER BY score DESC, popularity DESC
  LIMIT GREATEST(lim,1);
$$;

-- ICD-10
CREATE OR REPLACE FUNCTION axxia.resolve_icd10(q_in text, lim int DEFAULT 10)
RETURNS TABLE(code text, system text, display text, score numeric, is_exact boolean)
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT axxia._norm_text(q_in) AS s),
  cand AS (
    SELECT
      code::text AS code,
      'ICD10'::text AS system,
      title      AS display,
      popularity,
      (CASE WHEN code::text = (SELECT s FROM q) THEN 10 ELSE 0 END) AS score_code_exact,
      GREATEST(similarity(lower(title), (SELECT s FROM q)),
               similarity(lower(coalesce(array_to_string(synonyms,' '),'')), (SELECT s FROM q))) AS sim_best
    FROM axxia.cat_icd10
    WHERE code::text = (SELECT s FROM q)
       OR lower(title) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(coalesce(array_to_string(synonyms,' '),'')) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(title) % (SELECT s FROM q)
       OR lower(coalesce(array_to_string(synonyms,' '),'')) % (SELECT s FROM q)
  )
  SELECT code, system, display,
         ROUND(1.5*score_code_exact + 4.0*sim_best + 0.0005*popularity, 4) AS score,
         (score_code_exact > 0) AS is_exact
  FROM cand
  ORDER BY score DESC, popularity DESC
  LIMIT GREATEST(lim,1);
$$;

-- LOINC
CREATE OR REPLACE FUNCTION axxia.resolve_loinc(q_in text, lim int DEFAULT 10)
RETURNS TABLE(code text, system text, display text, score numeric, is_exact boolean)
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT axxia._norm_text(q_in) AS s),
  cand AS (
    SELECT
      loinc::text AS code,
      'LOINC'::text AS system,
      component AS display,
      popularity,
      (CASE WHEN loinc::text = (SELECT s FROM q) THEN 10 ELSE 0 END) AS score_code_exact,
      GREATEST(similarity(lower(component), (SELECT s FROM q)),
               similarity(lower(coalesce(array_to_string(synonyms,' '),'')), (SELECT s FROM q))) AS sim_best
    FROM axxia.cat_loinc_subset
    WHERE loinc::text = (SELECT s FROM q)
       OR lower(component) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(coalesce(array_to_string(synonyms,' '),'')) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(component) % (SELECT s FROM q)
       OR lower(coalesce(array_to_string(synonyms,' '),'')) % (SELECT s FROM q)
  )
  SELECT code, system, display,
         ROUND(1.5*score_code_exact + 4.0*sim_best + 0.0005*popularity, 4) AS score,
         (score_code_exact > 0) AS is_exact
  FROM cand
  ORDER BY score DESC, popularity DESC
  LIMIT GREATEST(lim,1);
$$;

-- ATC
CREATE OR REPLACE FUNCTION axxia.resolve_atc(q_in text, lim int DEFAULT 10)
RETURNS TABLE(code text, system text, display text, score numeric, is_exact boolean)
LANGUAGE sql STABLE AS $$
  WITH q AS (SELECT axxia._norm_text(q_in) AS s),
  cand AS (
    SELECT
      atc::text AS code,
      'ATC'::text AS system,
      name AS display,
      popularity,
      (CASE WHEN atc::text = (SELECT s FROM q) THEN 10 ELSE 0 END) AS score_code_exact,
      GREATEST(similarity(lower(name), (SELECT s FROM q)),
               similarity(lower(coalesce(array_to_string(synonyms,' '),'')), (SELECT s FROM q))) AS sim_best
    FROM axxia.cat_atc_subset
    WHERE atc::text = (SELECT s FROM q)
       OR lower(name) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(coalesce(array_to_string(synonyms,' '),'')) LIKE '%' || (SELECT s FROM q) || '%'
       OR lower(name) % (SELECT s FROM q)
       OR lower(coalesce(array_to_string(synonyms,' '),'')) % (SELECT s FROM q)
  )
  SELECT code, system, display,
         ROUND(1.5*score_code_exact + 4.0*sim_best + 0.0005*popularity, 4) AS score,
         (score_code_exact > 0) AS is_exact
  FROM cand
  ORDER BY score DESC, popularity DESC
  LIMIT GREATEST(lim,1);
$$;

-- AUTO resolver (regex heurística)
CREATE OR REPLACE FUNCTION axxia.resolve_auto(q_in text, lim int DEFAULT 10)
RETURNS TABLE(code text, system text, display text, score numeric, is_exact boolean)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  q text := axxia._norm_text(q_in);
BEGIN
  -- If looks like LOINC (e.g., 718-7)
  IF q ~ '^[0-9]{1,6}-[0-9]$' THEN
    RETURN QUERY SELECT * FROM axxia.resolve_loinc(q, lim);
    RETURN;
  END IF;
  -- If looks like ICD-10 (e.g., E11.9, I10, J06.9)
  IF q ~ '^[A-Z][0-9]{2}(\.[0-9A-Z]+)?$' THEN
    RETURN QUERY SELECT * FROM axxia.resolve_icd10(q, lim);
    RETURN;
  END IF;
  -- If looks like ATC (e.g., C10AA05)
  IF q ~ '^[A-Z][0-9][A-Z0-9]{3,}$' THEN
    RETURN QUERY SELECT * FROM axxia.resolve_atc(q, lim);
    RETURN;
  END IF;
  -- Default to SNOMED
  RETURN QUERY SELECT * FROM axxia.resolve_snomed(q, lim);
END;
$$;

-- 6) Popularity bump (safe no-op if not found)
CREATE OR REPLACE FUNCTION axxia.bump_popularity(sys text, code_in text)
RETURNS void LANGUAGE plpgsql VOLATILE AS $$
BEGIN
  CASE upper(sys)
    WHEN 'SNOMED' THEN
      UPDATE axxia.cat_snomed_subset SET popularity = popularity + 1 WHERE concept_id::text = code_in;
    WHEN 'ICD10' THEN
      UPDATE axxia.cat_icd10 SET popularity = popularity + 1 WHERE code::text = code_in;
    WHEN 'LOINC' THEN
      UPDATE axxia.cat_loinc_subset SET popularity = popularity + 1 WHERE loinc::text = code_in;
    WHEN 'ATC' THEN
      UPDATE axxia.cat_atc_subset SET popularity = popularity + 1 WHERE atc::text = code_in;
    ELSE
      NULL;
  END CASE;
END;
$$;

COMMIT;