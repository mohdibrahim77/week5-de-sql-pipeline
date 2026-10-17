-- =============================================================================
-- 04_triggers.sql  —  triggers that enforce warehouse rules
-- -----------------------------------------------------------------------------
--   trg_*_updated_at        BEFORE UPDATE  keep updated_at honest
--   trg_product_price_audit AFTER UPDATE   keep price history although dim is SCD1
--   trg_customer_history    BEFORE UPD/DEL make expired SCD2 versions immutable
-- Row-level triggers fire for every action of a MERGE as well, not just for
-- plain UPDATE / DELETE statements.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- updated_at stamping (one function, reused by several tables)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.tg_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_product_updated_at
    BEFORE UPDATE ON dw.dim_product
    FOR EACH ROW EXECUTE FUNCTION etl.tg_set_updated_at();

CREATE TRIGGER trg_store_updated_at
    BEFORE UPDATE ON dw.dim_store
    FOR EACH ROW EXECUTE FUNCTION etl.tg_set_updated_at();

-- -----------------------------------------------------------------------------
-- price audit — SCD Type 1 overwrites the price; this trigger remembers it.
-- The WHEN clause means the function is not even called for other updates.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.tg_audit_price()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO etl.price_audit (product_id, old_price, new_price)
    VALUES (NEW.product_id, OLD.unit_price, NEW.unit_price);
    RETURN NULL;                          -- return value is ignored for AFTER triggers
END;
$$;

CREATE TRIGGER trg_product_price_audit
    AFTER UPDATE OF unit_price ON dw.dim_product
    FOR EACH ROW
    WHEN (OLD.unit_price IS DISTINCT FROM NEW.unit_price)
    EXECUTE FUNCTION etl.tg_audit_price();

-- -----------------------------------------------------------------------------
-- SCD2 guard — history rows are append-only.
-- The only legal change to a version is expiring the *current* one.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION etl.tg_protect_scd2_history()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'dim_customer is append-only: cannot delete customer_sk %', OLD.customer_sk
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF NOT OLD.is_current THEN
        RAISE EXCEPTION 'customer_sk % is an expired SCD2 version and cannot be modified', OLD.customer_sk
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    IF (NEW.customer_id, NEW.full_name, NEW.email, NEW.city, NEW.segment, NEW.valid_from)
       IS DISTINCT FROM
       (OLD.customer_id, OLD.full_name, OLD.email, OLD.city, OLD.segment, OLD.valid_from) THEN
        RAISE EXCEPTION 'SCD2 attributes are immutable — insert a new version instead (customer_sk %)', OLD.customer_sk
            USING ERRCODE = 'integrity_constraint_violation';
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_customer_history
    BEFORE UPDATE OR DELETE ON dw.dim_customer
    FOR EACH ROW EXECUTE FUNCTION etl.tg_protect_scd2_history();
