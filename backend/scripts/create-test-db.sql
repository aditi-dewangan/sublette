-- Runs once, when the local database container is first created.
-- The main database (sublette) is created by the container itself.
CREATE DATABASE sublette_test;
\connect sublette_test
CREATE EXTENSION IF NOT EXISTS postgis;
