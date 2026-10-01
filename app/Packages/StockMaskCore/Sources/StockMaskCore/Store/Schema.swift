import GRDB

/// Database migrations. Never edit a shipped migration: add a new one.
///
/// Rules from ADR 005: keys are UUID text and the only UNIQUE constraint is the primary key, so
/// sync can be added later without a migration. Foreign keys and CHECKs are fine.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1: venue, catalog, sessions, commits, sheet, audit log") { db in
            try db.execute(sql: v1)
        }
        return migrator
    }

    /// `commit` is an SQL keyword, so the table name is always quoted.
    static let v1 = """
        CREATE TABLE venue (
            id          TEXT PRIMARY KEY NOT NULL,
            name        TEXT NOT NULL,
            country     TEXT NOT NULL,
            locale      TEXT NOT NULL,
            created_at  DATETIME NOT NULL
        );

        CREATE TABLE zone (
            id          TEXT PRIMARY KEY NOT NULL,
            venue_id    TEXT NOT NULL REFERENCES venue(id),
            name        TEXT NOT NULL,
            sort        INTEGER NOT NULL DEFAULT 0,
            map_file    TEXT,
            created_at  DATETIME NOT NULL
        );
        CREATE INDEX zone_venue ON zone(venue_id);

        CREATE TABLE sku (
            id              TEXT PRIMARY KEY NOT NULL,
            venue_id        TEXT NOT NULL REFERENCES venue(id),
            code            TEXT,
            name            TEXT NOT NULL,
            brand           TEXT,
            category        TEXT,
            size_ml         INTEGER CHECK (size_ml IS NULL OR size_ml > 0),
            units_per_case  INTEGER CHECK (units_per_case IS NULL OR units_per_case >= 1),
            unit_barcode    TEXT,
            case_gtin       TEXT,
            created_at      DATETIME NOT NULL,
            updated_at      DATETIME NOT NULL
        );
        CREATE INDEX sku_venue ON sku(venue_id);

        CREATE TABLE session (
            id               TEXT PRIMARY KEY NOT NULL,
            venue_id         TEXT NOT NULL REFERENCES venue(id),
            counter_name     TEXT NOT NULL,
            status           TEXT NOT NULL CHECK (status IN ('open', 'review', 'locked')),
            current_zone_id  TEXT REFERENCES zone(id),
            started_at       DATETIME NOT NULL,
            finished_at      DATETIME
        );
        CREATE INDEX session_venue ON session(venue_id);

        CREATE TABLE session_zone (
            id          TEXT PRIMARY KEY NOT NULL,
            session_id  TEXT NOT NULL REFERENCES session(id),
            zone_id     TEXT NOT NULL REFERENCES zone(id),
            sort        INTEGER NOT NULL
        );
        CREATE INDEX session_zone_session ON session_zone(session_id);

        -- pose: camera transform, JSON array of 16 floats, column-major.
        -- Item positions and the zone are in AR world space at commit time; anchor_id is the
        -- commit's ARAnchor, created at the counted zone's transform.
        CREATE TABLE "commit" (
            id             TEXT PRIMARY KEY NOT NULL,
            session_id     TEXT NOT NULL REFERENCES session(id),
            zone_id        TEXT NOT NULL REFERENCES zone(id),
            seq            INTEGER NOT NULL,
            anchor_id      TEXT,
            pose           TEXT,
            keyframe_file  TEXT,
            fired_by       TEXT,
            matched_count  INTEGER NOT NULL DEFAULT 0,
            drift_alarm    BOOLEAN NOT NULL DEFAULT 0,
            created_at     DATETIME NOT NULL,
            undone         BOOLEAN NOT NULL DEFAULT 0,
            undone_at      DATETIME
        );
        CREATE INDEX commit_session ON "commit"(session_id, seq);

        -- An oriented box: transform (JSON, 16 floats, column-major) and half extents in metres.
        CREATE TABLE counted_zone (
            id         TEXT PRIMARY KEY NOT NULL,
            commit_id  TEXT NOT NULL REFERENCES "commit"(id),
            transform  TEXT NOT NULL,
            half_x     REAL NOT NULL,
            half_y     REAL NOT NULL,
            half_z     REAL NOT NULL
        );
        CREATE INDEX counted_zone_commit ON counted_zone(commit_id);

        -- label is the letters of "Unknown A"; seq orders groups within the session.
        -- A product is only set with a confirmation (FR-31).
        CREATE TABLE item_group (
            id                 TEXT PRIMARY KEY NOT NULL,
            session_id         TEXT NOT NULL REFERENCES session(id),
            commit_id          TEXT REFERENCES "commit"(id),
            seq                INTEGER NOT NULL,
            label              TEXT NOT NULL,
            sku_id             TEXT REFERENCES sku(id),
            confirmed          BOOLEAN NOT NULL DEFAULT 0,
            suggested_sku_id   TEXT REFERENCES sku(id),
            suggestion_source  TEXT,
            created_at         DATETIME NOT NULL,
            named_at           DATETIME,
            CHECK (sku_id IS NULL OR confirmed = 1)
        );
        CREATE INDEX item_group_session ON item_group(session_id);

        -- class bottle_top: a bottle counted by its top (one unit, like a bottle).
        -- pos: the object's centre (the top for bottle_top); top: the bottle's top, when known.
        -- product_key: the counting engine's product key (SKU.productKey once the group is named).
        CREATE TABLE item (
            id               TEXT PRIMARY KEY NOT NULL,
            commit_id        TEXT NOT NULL REFERENCES "commit"(id),
            group_id         TEXT NOT NULL REFERENCES item_group(id),
            class            TEXT NOT NULL,
            confidence       REAL,
            pos_x            REAL NOT NULL,
            pos_y            REAL NOT NULL,
            pos_z            REAL NOT NULL,
            top_x            REAL,
            top_y            REAL,
            top_z            REAL,
            product_key      INTEGER,
            detection_index  INTEGER,
            crop_file        TEXT,
            removed          BOOLEAN NOT NULL DEFAULT 0,
            created_at       DATETIME NOT NULL
        );
        CREATE INDEX item_commit ON item(commit_id);
        CREATE INDEX item_group_id ON item(group_id);

        CREATE TABLE manual_line (
            id           TEXT PRIMARY KEY NOT NULL,
            session_id   TEXT NOT NULL REFERENCES session(id),
            zone_id      TEXT NOT NULL REFERENCES zone(id),
            sku_id       TEXT NOT NULL REFERENCES sku(id),
            full_cases   INTEGER NOT NULL CHECK (full_cases >= 0),
            loose_units  INTEGER NOT NULL CHECK (loose_units >= 0),
            note         TEXT,
            created_at   DATETIME NOT NULL,
            updated_at   DATETIME NOT NULL
        );
        CREATE INDEX manual_line_session ON manual_line(session_id);

        -- Not in PRD §11: kept so review can warn about possible misses left (FR-35).
        CREATE TABLE possible_miss (
            id               TEXT PRIMARY KEY NOT NULL,
            commit_id        TEXT NOT NULL REFERENCES "commit"(id),
            class            TEXT NOT NULL,
            confidence       REAL,
            pos_x            REAL,
            pos_y            REAL,
            pos_z            REAL,
            top_x            REAL,
            top_y            REAL,
            top_z            REAL,
            detection_index  INTEGER,
            crop_file        TEXT,
            status           TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'added', 'dismissed')),
            item_id          TEXT REFERENCES item(id),
            resolved_at      DATETIME
        );
        CREATE INDEX possible_miss_commit ON possible_miss(commit_id);

        -- The audit trail: append-only, enforced by the triggers below.
        CREATE TABLE event (
            id          TEXT PRIMARY KEY NOT NULL,
            venue_id    TEXT REFERENCES venue(id),
            session_id  TEXT REFERENCES session(id),
            ts          DATETIME NOT NULL,
            type        TEXT NOT NULL,
            payload     TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX event_session ON event(session_id, ts);

        CREATE TRIGGER event_no_update BEFORE UPDATE ON event
        BEGIN
            SELECT RAISE(ABORT, 'event is append-only');
        END;

        CREATE TRIGGER event_no_delete BEFORE DELETE ON event
        BEGIN
            SELECT RAISE(ABORT, 'event is append-only');
        END;
        """
}
