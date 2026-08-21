-- Star schema. Dimensions are created and loaded from raw; facts are created
-- empty (the monthly panel is Phase 1).
--
-- Each dimension gets an unknown member with key -1 so facts can use NOT NULL
-- foreign keys when a lookup misses.
-- ============================================================== dimensions
CREATE TABLE IF NOT EXISTS core.dim_date (
    date_key int PRIMARY KEY,
    date date NOT NULL UNIQUE,
    year int NOT NULL,
    quarter int NOT NULL,
    month int NOT NULL,
    is_month_end boolean NOT NULL
);
INSERT INTO core.dim_date
SELECT to_char(d, 'YYYYMMDD')::int,
    d::date,
    extract(
        year
        FROM d
    )::int,
    extract(
        quarter
        FROM d
    )::int,
    extract(
        month
        FROM d
    )::int,
    d::date = (
        date_trunc('month', d) + interval '1 month - 1 day'
    )::date
FROM generate_series('2023-01-01'::date, '2025-12-31'::date, '1 day') d ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS core.dim_customer (
    customer_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id text NOT NULL UNIQUE,
    gender text,
    age int,
    is_senior boolean,
    is_married boolean,
    number_of_dependents int,
    number_of_referrals int
);
INSERT INTO core.dim_customer (customer_key, customer_id) OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN') ON CONFLICT DO NOTHING;
INSERT INTO core.dim_customer (
        customer_id,
        gender,
        age,
        is_senior,
        is_married,
        number_of_dependents,
        number_of_referrals
    )
SELECT d."CustomerID",
    d."Gender",
    NULLIF(d."Age", '')::int,
    d."SeniorCitizen" = 'Yes',
    d."Married" = 'Yes',
    NULLIF(d."NumberofDependents", '')::int,
    NULLIF(s."NumberofReferrals", '')::int
FROM raw.demographics d
    LEFT JOIN raw.services s ON s."CustomerID" = d."CustomerID" ON CONFLICT DO NOTHING;
-- Country and State are dropped: single-valued, so they carry no information.
CREATE TABLE IF NOT EXISTS core.dim_location (
    location_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city text,
    zip_code text NOT NULL UNIQUE,
    latitude numeric(9, 6),
    longitude numeric(9, 6),
    population int
);
INSERT INTO core.dim_location (location_key, zip_code) OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN') ON CONFLICT DO NOTHING;
INSERT INTO core.dim_location (city, zip_code, latitude, longitude, population)
SELECT DISTINCT ON (l."ZipCode") l."City",
    l."ZipCode",
    NULLIF(l."Latitude", '')::numeric,
    NULLIF(l."Longitude", '')::numeric,
    NULLIF(p."Population", '')::int
FROM raw.location l
    LEFT JOIN raw.population p ON p."ZipCode" = l."ZipCode" ON CONFLICT DO NOTHING;
CREATE TABLE IF NOT EXISTS core.dim_contract (
    contract_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_type text NOT NULL,
    paperless_billing boolean NOT NULL,
    payment_method text NOT NULL,
    UNIQUE (contract_type, paperless_billing, payment_method)
);
INSERT INTO core.dim_contract (
        contract_key,
        contract_type,
        paperless_billing,
        payment_method
    ) OVERRIDING SYSTEM VALUE
VALUES (-1, 'Unknown', false, 'Unknown') ON CONFLICT DO NOTHING;
INSERT INTO core.dim_contract (contract_type, paperless_billing, payment_method)
SELECT DISTINCT "Contract",
    "PaperlessBilling" = 'Yes',
    "PaymentMethod"
FROM raw.services
WHERE "Contract" IS NOT NULL ON CONFLICT DO NOTHING;
-- Junk dimension: twelve service flags in one key instead of twelve joins.
CREATE TABLE IF NOT EXISTS core.dim_service (
    service_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    phone_service boolean NOT NULL,
    multiple_lines boolean NOT NULL,
    internet_service boolean NOT NULL,
    internet_type text NOT NULL,
    online_security boolean NOT NULL,
    online_backup boolean NOT NULL,
    device_protection boolean NOT NULL,
    premium_tech_support boolean NOT NULL,
    streaming_tv boolean NOT NULL,
    streaming_movies boolean NOT NULL,
    streaming_music boolean NOT NULL,
    unlimited_data boolean NOT NULL,
    UNIQUE (
        phone_service,
        multiple_lines,
        internet_service,
        internet_type,
        online_security,
        online_backup,
        device_protection,
        premium_tech_support,
        streaming_tv,
        streaming_movies,
        streaming_music,
        unlimited_data
    )
);
INSERT INTO core.dim_service OVERRIDING SYSTEM VALUE
VALUES (
        -1,
        false,
        false,
        false,
        'Unknown',
        false,
        false,
        false,
        false,
        false,
        false,
        false,
        false
    ) ON CONFLICT DO NOTHING;
INSERT INTO core.dim_service (
        phone_service,
        multiple_lines,
        internet_service,
        internet_type,
        online_security,
        online_backup,
        device_protection,
        premium_tech_support,
        streaming_tv,
        streaming_movies,
        streaming_music,
        unlimited_data
    )
SELECT DISTINCT "PhoneService" = 'Yes',
    "MultipleLines" = 'Yes',
    "InternetService" = 'Yes',
    COALESCE(NULLIF("InternetType", ''), 'None'),
    "OnlineSecurity" = 'Yes',
    "OnlineBackup" = 'Yes',
    "DeviceProtectionPlan" = 'Yes',
    "PremiumTechSupport" = 'Yes',
    "StreamingTV" = 'Yes',
    "StreamingMovies" = 'Yes',
    "StreamingMusic" = 'Yes',
    "UnlimitedData" = 'Yes'
FROM raw.services ON CONFLICT DO NOTHING;
-- The LLM's closed action space. discount_pct / cost_to_serve / eligibility are
-- OUR parameters, not source data -- the CSV carries only the offer label.
CREATE TABLE IF NOT EXISTS core.dim_offer (
    offer_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offer_id text NOT NULL UNIQUE,
    discount_pct numeric(5, 2),
    cost_to_serve numeric(8, 2),
    eligibility_rule_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_active boolean NOT NULL DEFAULT true
);
INSERT INTO core.dim_offer (offer_key, offer_id) OVERRIDING SYSTEM VALUE
VALUES (-1, 'UNKNOWN') ON CONFLICT DO NOTHING;
INSERT INTO core.dim_offer (offer_id)
SELECT DISTINCT COALESCE(NULLIF("Offer", ''), 'None')
FROM raw.services ON CONFLICT DO NOTHING;
-- Feeds the RAG knowledge base. FORBIDDEN as a model feature: populated only for
-- churned customers, so its presence alone reveals the label.
CREATE TABLE IF NOT EXISTS core.dim_churn_reason (
    reason_key int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category text NOT NULL,
    reason_text text NOT NULL,
    UNIQUE (category, reason_text)
);
INSERT INTO core.dim_churn_reason (reason_key, category, reason_text) OVERRIDING SYSTEM VALUE
VALUES (-1, 'Unknown', 'Unknown') ON CONFLICT DO NOTHING;
INSERT INTO core.dim_churn_reason (category, reason_text)
SELECT DISTINCT "ChurnCategory",
    "ChurnReason"
FROM raw.status
WHERE NULLIF("ChurnReason", '') IS NOT NULL ON CONFLICT DO NOTHING;
-- ==================================================================== facts
-- GRAIN: one row per customer per month. as_of_date is the point-in-time
-- anchor: features may use data at or before it, the label comes from
-- (as_of_date, as_of_date + 30d]. One row per customer would remove the time
-- axis and make label leakage unavoidable.
CREATE TABLE IF NOT EXISTS core.fct_customer_month (
    customer_key int NOT NULL REFERENCES core.dim_customer,
    date_key int NOT NULL REFERENCES core.dim_date,
    contract_key int NOT NULL REFERENCES core.dim_contract,
    service_key int NOT NULL REFERENCES core.dim_service,
    location_key int NOT NULL REFERENCES core.dim_location,
    offer_key int NOT NULL REFERENCES core.dim_offer,
    tenure_months int,
    monthly_charge numeric(10, 2),
    total_charges numeric(12, 2),
    total_revenue numeric(12, 2),
    total_refunds numeric(10, 2),
    total_extra_data_charges numeric(10, 2),
    total_long_distance_charges numeric(12, 2),
    avg_monthly_gb_download numeric(10, 2),
    avg_monthly_long_distance_charges numeric(10, 2),
    customer_status text,
    churn_flag_next_30d int NOT NULL DEFAULT 0,
    as_of_date date NOT NULL,
    PRIMARY KEY (customer_key, date_key),
    -- Guards the 'Joined' customers (tenure 1-3): if the panel builder ever
    -- produces a negative tenure the insert fails instead of poisoning training.
    CHECK (tenure_months >= 0),
    CHECK (churn_flag_next_30d IN (0, 1))
);
-- Closes the loop: recommendation -> agent decision -> outcome.
CREATE TABLE IF NOT EXISTS core.fct_retention_action (
    action_key bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_key int NOT NULL REFERENCES core.dim_customer,
    date_key int NOT NULL REFERENCES core.dim_date,
    offer_key int NOT NULL REFERENCES core.dim_offer,
    prediction_key bigint,
    llm_rationale text,
    evidence_chunk_ids jsonb NOT NULL DEFAULT '[]'::jsonb,
    agent_decision text,
    accepted_flag boolean,
    outcome_churn_flag boolean,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_fcm_date ON core.fct_customer_month (date_key);
CREATE INDEX IF NOT EXISTS ix_fcm_as_of ON core.fct_customer_month (as_of_date);
