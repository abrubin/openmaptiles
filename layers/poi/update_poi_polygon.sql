DROP TRIGGER IF EXISTS trigger_flag ON osm_poi_polygon;
DROP TRIGGER IF EXISTS trigger_store ON osm_poi_polygon;
DROP TRIGGER IF EXISTS trigger_refresh ON poi_polygon.updates;

CREATE SCHEMA IF NOT EXISTS poi_polygon;

CREATE TABLE IF NOT EXISTS poi_polygon.osm_ids
(
    osm_id bigint
);

-- etldoc:  osm_poi_polygon ->  osm_poi_polygon

CREATE OR REPLACE FUNCTION update_poi_polygon(full_update boolean) RETURNS void AS
$$
    UPDATE osm_poi_polygon
    SET geometry =
            CASE
                WHEN ST_NPoints(ST_ConvexHull(geometry)) = ST_NPoints(geometry)
                    THEN ST_Centroid(geometry)
                ELSE ST_PointOnSurface(geometry)
                END
    WHERE (full_update OR osm_id IN (SELECT osm_id FROM poi_polygon.osm_ids))
      AND ST_GeometryType(geometry) <> 'ST_Point';

    UPDATE osm_poi_polygon
    SET subclass = 'subway'
    WHERE (full_update OR osm_id IN (SELECT osm_id FROM poi_polygon.osm_ids))
      AND station = 'subway'
      AND subclass = 'station';

    UPDATE osm_poi_polygon
    SET subclass = 'halt'
    WHERE (full_update OR osm_id IN (SELECT osm_id FROM poi_polygon.osm_ids))
      AND funicular = 'yes'
      AND subclass = 'station';

    UPDATE osm_poi_polygon
    SET tags = update_tags(tags, geometry)
    WHERE (full_update OR osm_id IN (SELECT osm_id FROM poi_polygon.osm_ids))
      AND COALESCE(tags->'name:latin', tags->'name:nonlatin', tags->'name_int') IS NULL
      AND tags != update_tags(tags, geometry);

$$ LANGUAGE SQL;

SELECT update_poi_polygon(true);

-- Handle updates

CREATE OR REPLACE FUNCTION poi_polygon.store() RETURNS trigger AS
$$
BEGIN
    IF (tg_op = 'DELETE') THEN
        INSERT INTO poi_polygon.osm_ids VALUES (OLD.osm_id);
    ELSE
        INSERT INTO poi_polygon.osm_ids VALUES (NEW.osm_id);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS poi_polygon.updates
(
    id serial PRIMARY KEY,
    t text,
    UNIQUE (t)
);
CREATE OR REPLACE FUNCTION poi_polygon.flag() RETURNS trigger AS
$$
BEGIN
    INSERT INTO poi_polygon.updates(t) VALUES ('y') ON CONFLICT(t) DO NOTHING;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION poi_polygon.refresh() RETURNS trigger AS
$$
BEGIN
    RAISE LOG 'Refresh poi_polygon';
    PERFORM update_poi_polygon(false);
    -- noinspection SqlWithoutWhere
    DELETE FROM poi_polygon.osm_ids;
    -- noinspection SqlWithoutWhere
    DELETE FROM poi_polygon.updates;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_store
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_poi_polygon
    FOR EACH ROW
EXECUTE PROCEDURE poi_polygon.store();

CREATE TRIGGER trigger_flag
    AFTER INSERT OR UPDATE OR DELETE
    ON osm_poi_polygon
    FOR EACH STATEMENT
EXECUTE PROCEDURE poi_polygon.flag();

CREATE CONSTRAINT TRIGGER trigger_refresh
    AFTER INSERT
    ON poi_polygon.updates
    INITIALLY DEFERRED
    FOR EACH ROW
EXECUTE PROCEDURE poi_polygon.refresh();
