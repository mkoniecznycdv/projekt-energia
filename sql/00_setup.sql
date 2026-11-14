-- region europe-central2 = Warszawa

CREATE SCHEMA IF NOT EXISTS bronze OPTIONS (location = 'europe-central2', description = 'surowe dane z api');
CREATE SCHEMA IF NOT EXISTS silver OPTIONS (location = 'europe-central2', description = 'dane po czyszczeniu, UTC');
CREATE SCHEMA IF NOT EXISTS gold   OPTIONS (location = 'europe-central2', description = 'tabele pod dashboard');
CREATE SCHEMA IF NOT EXISTS meta   OPTIONS (location = 'europe-central2', description = 'watermarki');

-- BRONZE
-- partycja dzienna zeby przy ponownym ladowaniu dnia ruszac tylko 1 partycje
-- klaster po source bo w silver zawsze czytamy jedno zrodlo naraz
CREATE TABLE IF NOT EXISTS bronze.raw_records (
  source        STRING    NOT NULL OPTIONS (description = 'endpoint, np. rce-pln, gen-jw, weather-poznan'),
  business_date DATE      NOT NULL OPTIONS (description = 'dzien z nazwy pliku'),
  payload       STRING    NOT NULL OPTIONS (description = 'surowy json'),
  source_file   STRING    NOT NULL OPTIONS (description = 'sciezka gs://'),
  ingested_at   TIMESTAMP NOT NULL OPTIONS (description = 'kiedy zaladowane do BQ')
)
PARTITION BY business_date
CLUSTER BY source
OPTIONS (description = 'surowe dane PSE + Open-Meteo, tylko append');

-- SILVER
-- partycje miesieczne a nie dzienne - 96 wierszy na dzien to za malo,
-- byloby mnostwo malych partycji. filtr po business_date i tak tnie do miesiecy
CREATE TABLE IF NOT EXISTS silver.prices (
  ts_utc        TIMESTAMP NOT NULL OPTIONS (description = 'poczatek kwadransa UTC'),
  business_date DATE      NOT NULL,
  price_pln_mwh NUMERIC            OPTIONS (description = 'RCE, moze byc ujemna'),
  published_at  TIMESTAMP,
  ingested_at   TIMESTAMP NOT NULL
)
PARTITION BY DATE_TRUNC(business_date, MONTH);

CREATE TABLE IF NOT EXISTS silver.generation_mix (
  ts_utc                  TIMESTAMP NOT NULL,
  business_date           DATE      NOT NULL,
  demand_mw               NUMERIC OPTIONS (description = 'zapotrzebowanie'),
  pv_mw                   NUMERIC OPTIONS (description = 'fotowoltaika'),
  wind_mw                 NUMERIC OPTIONS (description = 'wiatr'),
  exchange_parallel_mw    NUMERIC OPTIONS (description = 'swm_p - wymiana rownolegla'),
  exchange_nonparallel_mw NUMERIC OPTIONS (description = 'swm_np - wymiana nierownolegla'),
  ingested_at             TIMESTAMP NOT NULL
)
PARTITION BY DATE_TRUNC(business_date, MONTH);

CREATE TABLE IF NOT EXISTS silver.system_load (
  ts_utc           TIMESTAMP NOT NULL,
  business_date    DATE      NOT NULL,
  load_forecast_mw NUMERIC,
  load_actual_mw   NUMERIC,
  ingested_at      TIMESTAMP NOT NULL
)
PARTITION BY DATE_TRUNC(business_date, MONTH);

-- najwieksza tabela (~100 blokow x 96 kwadransow dziennie)
-- klaster po elektrowni + wymuszony filtr partycji, wtedy zapytanie
-- np. tylko o Karolin czyta malo danych
CREATE TABLE IF NOT EXISTS silver.unit_generation (
  ts_utc         TIMESTAMP NOT NULL,
  business_date  DATE      NOT NULL,
  power_plant    STRING    NOT NULL,
  resource_code  STRING    NOT NULL,
  operating_mode STRING    NOT NULL OPTIONS (description = 'Generacja albo Pobór (elektrownie pompowe)'),
  power_mw       NUMERIC,
  ingested_at    TIMESTAMP NOT NULL
)
PARTITION BY DATE_TRUNC(business_date, MONTH)
CLUSTER BY power_plant, resource_code
OPTIONS (require_partition_filter = TRUE);

CREATE TABLE IF NOT EXISTS silver.weather_poznan (
  ts_utc                  TIMESTAMP NOT NULL OPTIONS (description = 'pelna godzina UTC'),
  business_date           DATE      NOT NULL OPTIONS (description = 'dzien UTC z zapytania do api'),
  temperature_c           FLOAT64,
  wind_speed_100m_kmh     FLOAT64,
  shortwave_radiation_wm2 FLOAT64,
  cloud_cover_pct         FLOAT64,
  ingested_at             TIMESTAMP NOT NULL
)
PARTITION BY DATE_TRUNC(business_date, MONTH);

-- GOLD
-- tylko tabela faktow, agregaty robi pipeline.sql
CREATE TABLE IF NOT EXISTS gold.energy_15min (
  ts_utc                  TIMESTAMP NOT NULL,
  ts_local                DATETIME  NOT NULL OPTIONS (description = 'czas polski'),
  business_date           DATE      NOT NULL,
  hour_local              INT64     NOT NULL,
  dow_iso                 INT64     NOT NULL OPTIONS (description = '1 = pon, 7 = niedz'),
  price_pln_mwh           NUMERIC,
  demand_mw               NUMERIC,
  pv_mw                   NUMERIC,
  wind_mw                 NUMERIC,
  oze_share               FLOAT64   OPTIONS (description = '(pv + wiatr) / zapotrzebowanie'),
  load_forecast_mw        NUMERIC,
  load_actual_mw          NUMERIC,
  temperature_c           FLOAT64   OPTIONS (description = 'Poznan'),
  wind_speed_100m_kmh     FLOAT64   OPTIONS (description = 'Poznan'),
  shortwave_radiation_wm2 FLOAT64   OPTIONS (description = 'Poznan'),
  cloud_cover_pct         FLOAT64   OPTIONS (description = 'Poznan')
)
PARTITION BY DATE_TRUNC(business_date, MONTH)
CLUSTER BY hour_local;

CREATE TABLE IF NOT EXISTS meta.watermarks (
  layer            STRING    NOT NULL,
  last_ingested_at TIMESTAMP NOT NULL,
  updated_at       TIMESTAMP NOT NULL
);
