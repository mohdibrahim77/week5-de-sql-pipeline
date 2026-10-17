#!/usr/bin/env python3
"""
Isolation levels, demonstrated with two real concurrent connections.

    pip install psycopg2-binary
    python scripts/isolation_demo.py "dbname=grokmart user=postgres host=localhost port=5432"

Works on a scratch copy (etl.iso_demo) of dw.dim_product that is dropped at
the end, so the warehouse itself is never touched.

Scenarios:
  1. READ COMMITTED  -> non-repeatable read
  2. REPEATABLE READ -> stable snapshot, but a concurrent update is rejected
  3. READ COMMITTED  -> lost update (read-modify-write race)
  4. SERIALIZABLE    -> write skew detected and aborted
"""

import sys

import psycopg2
from psycopg2 import errors
from psycopg2.extensions import (ISOLATION_LEVEL_READ_COMMITTED, ISOLATION_LEVEL_REPEATABLE_READ,
                                 ISOLATION_LEVEL_SERIALIZABLE)

DSN = sys.argv[1] if len(sys.argv) > 1 else "dbname=grokmart user=postgres host=localhost port=5432"
PID = "P005"


def connect(level):
    c = psycopg2.connect(DSN)
    c.set_isolation_level(level)
    return c


def price(cur):
    cur.execute("SELECT unit_price FROM etl.iso_demo WHERE product_id = %s", (PID,))
    return cur.fetchone()[0]


def set_price(conn, value):
    with conn.cursor() as cur:
        cur.execute("UPDATE etl.iso_demo SET unit_price = %s WHERE product_id = %s", (value, PID))
    conn.commit()


def header(title):
    print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")


def main():
    admin = connect(ISOLATION_LEVEL_READ_COMMITTED)
    with admin.cursor() as cur:
        cur.execute("DROP TABLE IF EXISTS etl.iso_demo")
        cur.execute("CREATE TABLE etl.iso_demo AS "
                    "SELECT product_id, unit_price, is_active FROM dw.dim_product")
        cur.execute("ALTER TABLE etl.iso_demo ADD PRIMARY KEY (product_id)")
        original = price(cur)
    admin.commit()

    try:
        # ------------------------------------------------------------------ 1
        header("1. READ COMMITTED - non-repeatable read")
        t1 = connect(ISOLATION_LEVEL_READ_COMMITTED)
        c1 = t1.cursor()
        a = price(c1)
        print(f"T1 reads price            : {a}")
        set_price(admin, a + 100)
        print(f"T2 updates + commits      : {a + 100}")
        b = price(c1)
        print(f"T1 reads again (same txn) : {b}   <- changed inside one transaction")
        t1.rollback()
        set_price(admin, original)

        # ------------------------------------------------------------------ 2
        header("2. REPEATABLE READ - one snapshot for the whole transaction")
        t1 = connect(ISOLATION_LEVEL_REPEATABLE_READ)
        c1 = t1.cursor()
        a = price(c1)
        print(f"T1 reads price            : {a}")
        set_price(admin, a + 100)
        print(f"T2 updates + commits      : {a + 100}")
        b = price(c1)
        print(f"T1 reads again (same txn) : {b}   <- still the snapshot value")
        try:
            c1.execute("UPDATE etl.iso_demo SET unit_price = unit_price + 1 WHERE product_id = %s", (PID,))
            print("T1 update succeeded (unexpected)")
        except errors.SerializationFailure as e:
            print(f"T1 tries to update        : ERROR {e.pgcode} {e.pgerror.splitlines()[0]}")
            print("                            -> application must retry the transaction")
        t1.rollback()
        set_price(admin, original)

        # ------------------------------------------------------------------ 3
        header("3. READ COMMITTED - lost update (read, compute in app, write)")
        t1, t2 = connect(ISOLATION_LEVEL_READ_COMMITTED), connect(ISOLATION_LEVEL_READ_COMMITTED)
        c1, c2 = t1.cursor(), t2.cursor()
        p1, p2 = price(c1), price(c2)
        print(f"T1 and T2 both read       : {p1}")
        c1.execute("UPDATE etl.iso_demo SET unit_price = %s WHERE product_id = %s", (p1 + 10, PID))
        t1.commit()
        print(f"T1 writes {p1}+10 and commits")
        c2.execute("UPDATE etl.iso_demo SET unit_price = %s WHERE product_id = %s", (p2 + 20, PID))
        t2.commit()
        print(f"T2 writes {p2}+20 and commits")
        with admin.cursor() as cur:
            final = price(cur)
        admin.commit()
        print(f"final price               : {final}   (expected {original + 30}: T1's +10 was LOST)")
        print("fix: UPDATE ... SET unit_price = unit_price + 10   (atomic)  or  SELECT ... FOR UPDATE")
        set_price(admin, original)

        # ------------------------------------------------------------------ 4
        header("4. SERIALIZABLE - write skew is detected")
        # rule: at least one of P001/P002 must stay active. Each txn checks, then deactivates the OTHER one.
        with admin.cursor() as cur:
            cur.execute("UPDATE etl.iso_demo SET is_active = true WHERE product_id IN ('P001','P002')")
        admin.commit()
        t1, t2 = connect(ISOLATION_LEVEL_SERIALIZABLE), connect(ISOLATION_LEVEL_SERIALIZABLE)
        c1, c2 = t1.cursor(), t2.cursor()
        q = "SELECT count(*) FROM etl.iso_demo WHERE product_id IN ('P001','P002') AND is_active"
        c1.execute(q); n1 = c1.fetchone()[0]
        c2.execute(q); n2 = c2.fetchone()[0]
        print(f"T1 sees {n1} active, T2 sees {n2} active -> both think it is safe to deactivate one")
        c1.execute("UPDATE etl.iso_demo SET is_active = false WHERE product_id = 'P001'")
        c2.execute("UPDATE etl.iso_demo SET is_active = false WHERE product_id = 'P002'")
        t1.commit()
        print("T1 commits")
        try:
            t2.commit()
            print("T2 commits  (write skew happened!)")
        except errors.SerializationFailure as e:
            print(f"T2 commit -> ERROR {e.pgcode}: {e.pgerror.splitlines()[0]}")
            print("            under READ COMMITTED / REPEATABLE READ both would have committed")
    finally:
        admin.rollback()
        with admin.cursor() as cur:
            cur.execute("DROP TABLE IF EXISTS etl.iso_demo")
        admin.commit()
        admin.close()
    print("\nScratch table etl.iso_demo dropped - warehouse untouched.")


if __name__ == "__main__":
    main()
