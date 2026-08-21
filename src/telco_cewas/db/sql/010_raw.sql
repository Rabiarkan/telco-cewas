-- Landing tables. Every column is text on purpose: declaring a type is a
-- transformation, and raw performs none. TotalCharges is blank for zero-tenure
-- customers, which would abort the whole COPY against a numeric column.
CREATE TABLE IF NOT EXISTS raw.demographics (
    "CustomerID" text,
    "Count" text,
    "Gender" text,
    "Age" text,
    "Under30" text,
    "SeniorCitizen" text,
    "Married" text,
    "Dependents" text,
    "NumberofDependents" text,
    _source_file text
);
CREATE TABLE IF NOT EXISTS raw.location (
    "CustomerID" text,
    "Count" text,
    "Country" text,
    "State" text,
    "City" text,
    "ZipCode" text,
    "Latitude" text,
    "Longitude" text,
    _source_file text
);
CREATE TABLE IF NOT EXISTS raw.population (
    "ID" text,
    "ZipCode" text,
    "Population" text,
    _source_file text
);
CREATE TABLE IF NOT EXISTS raw.services (
    "CustomerID" text,
    "Count" text,
    "Quarter" text,
    "ReferredaFriend" text,
    "NumberofReferrals" text,
    "TenureinMonths" text,
    "Offer" text,
    "PhoneService" text,
    "AvgMonthlyLongDistanceCharges" text,
    "MultipleLines" text,
    "InternetService" text,
    "InternetType" text,
    "AvgMonthlyGBDownload" text,
    "OnlineSecurity" text,
    "OnlineBackup" text,
    "DeviceProtectionPlan" text,
    "PremiumTechSupport" text,
    "StreamingTV" text,
    "StreamingMovies" text,
    "StreamingMusic" text,
    "UnlimitedData" text,
    "Contract" text,
    "PaperlessBilling" text,
    "PaymentMethod" text,
    "MonthlyCharge" text,
    "TotalCharges" text,
    "TotalRefunds" text,
    "TotalExtraDataCharges" text,
    "TotalLongDistanceCharges" text,
    "TotalRevenue" text,
    _source_file text
);
CREATE TABLE IF NOT EXISTS raw.status (
    "CustomerID" text,
    "Count" text,
    "Quarter" text,
    "CustomerStatus" text,
    "ChurnLabel" text,
    "ChurnValue" text,
    "ChurnCategory" text,
    "ChurnReason" text,
    _source_file text
);
