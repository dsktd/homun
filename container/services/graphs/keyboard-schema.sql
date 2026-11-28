-- The Moonlander usage database (moonlander-leds on the host writes it, Grafana reads it
-- read-only). Mirrors the daemon's own schema so an empty file answers every query; the
-- daemon fills it within five minutes of the keyboard being connected.
CREATE TABLE IF NOT EXISTS key_usage (
    hour INTEGER, layer TEXT, row INTEGER, col INTEGER, count INTEGER,
    PRIMARY KEY (hour, layer, row, col));
CREATE TABLE IF NOT EXISTS mod_usage (
    hour INTEGER, mods TEXT, row INTEGER, col INTEGER, count INTEGER,
    PRIMARY KEY (hour, mods, row, col));
CREATE TABLE IF NOT EXISTS dualrole_usage (
    hour INTEGER, row INTEGER, col INTEGER, kind TEXT, count INTEGER,
    PRIMARY KEY (hour, row, col, kind));
CREATE TABLE IF NOT EXISTS layer_usage (
    hour INTEGER, layer TEXT, entries INTEGER, held_ms INTEGER,
    PRIMARY KEY (hour, layer));
CREATE TABLE IF NOT EXISTS key_layout (
    row INTEGER, col INTEGER, half TEXT, finger TEXT, x REAL, y REAL, label TEXT,
    PRIMARY KEY (row, col));
CREATE TABLE IF NOT EXISTS key_label (
    layer TEXT, row INTEGER, col INTEGER, label TEXT,
    PRIMARY KEY (layer, row, col));
