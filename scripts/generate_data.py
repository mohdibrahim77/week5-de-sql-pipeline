#!/usr/bin/env python3
"""
Deterministic data generator for the GrokMart DE SQL pipeline.

Produces two CSV batches that exercise every part of the pipeline:

  data/batch1/  - initial full load (Jan-Apr 2026)
  data/batch2/  - incremental load (May-Jun 2026) containing:
                    * customers that moved city / changed segment  -> SCD Type 2
                    * products with new prices / discontinued       -> SCD Type 1
                    * stores re-assigned to another region          -> SCD Type 3
                    * late corrections to April sales               -> UPSERT
                    * replayed clickstream events                   -> ON CONFLICT DO NOTHING
                    * deliberately bad rows                         -> rejected / quarantined

Pure standard library. Same seed => byte-identical files.

    python scripts/generate_data.py
"""

import csv
import json
import random
from datetime import date, datetime, timedelta
from pathlib import Path

SEED = 42
ROOT = Path(__file__).resolve().parent.parent / "data"

BATCH1_SALES = 30_000
BATCH2_SALES = 15_000
BATCH1_EVENTS = 8_000
BATCH2_EVENTS = 4_000

CITIES = {
    "NORTH": ["Delhi", "Chandigarh", "Lucknow", "Jaipur"],
    "SOUTH": ["Bengaluru", "Chennai", "Hyderabad", "Kochi"],
    "EAST": ["Kolkata", "Bhubaneswar", "Patna", "Guwahati"],
    "WEST": ["Mumbai", "Pune", "Ahmedabad", "Surat"],
}
ALL_CITIES = [c for cs in CITIES.values() for c in cs]

FIRST = ["Aarav", "Vivaan", "Aditya", "Vihaan", "Arjun", "Sai", "Reyansh", "Krishna",
         "Ishaan", "Rohan", "Ananya", "Diya", "Aadhya", "Saanvi", "Myra", "Kiara",
         "Priya", "Neha", "Kavya", "Meera", "Tarun", "Ibrahim", "Fatima", "Zoya",
         "Rahul", "Sneha", "Vikram", "Pooja", "Karan", "Nisha"]
LAST = ["Sharma", "Verma", "Gupta", "Iyer", "Reddy", "Nair", "Khan", "Das", "Bose",
        "Patel", "Shah", "Mehta", "Singh", "Kaur", "Rao", "Pillai", "Mishra", "Joshi",
        "Chatterjee", "Banerjee"]
SEGMENTS = ["Consumer", "Corporate", "Small Business"]

CATALOG = {
    "Electronics": ["Wireless Earbuds", "Smart Watch", "Bluetooth Speaker", "Power Bank",
                    "USB-C Hub", "Mechanical Keyboard", "Gaming Mouse", "Webcam HD",
                    "Portable SSD 1TB", "Noise Cancelling Headphones"],
    "Home & Kitchen": ["Air Fryer", "Mixer Grinder", "Electric Kettle", "Non-stick Pan Set",
                       "Water Purifier", "Induction Cooktop", "Coffee Maker", "Steel Bottle",
                       "Pressure Cooker", "Rice Cooker"],
    "Fashion": ["Denim Jacket", "Running Shoes", "Cotton Kurta", "Leather Wallet",
                "Sunglasses", "Silk Saree", "Formal Shirt", "Sneakers", "Backpack", "Wrist Watch"],
    "Books": ["Designing Data-Intensive Apps", "SQL Performance Explained", "The Data Warehouse Toolkit",
              "Fundamentals of Data Engineering", "Clean Code", "Python Crash Course",
              "Atomic Habits", "Deep Work", "The Pragmatic Programmer", "Streaming Systems"],
    "Sports": ["Yoga Mat", "Cricket Bat", "Football", "Dumbbell Set 10kg", "Badminton Racket",
               "Cycling Helmet", "Skipping Rope", "Resistance Bands", "Tennis Balls", "Gym Gloves"],
    "Beauty": ["Face Wash", "Sunscreen SPF50", "Hair Dryer", "Beard Trimmer", "Lip Balm",
               "Moisturiser", "Perfume 100ml", "Shampoo", "Face Serum", "Kajal"],
}
PRICE_RANGE = {
    "Electronics": (799, 8999), "Home & Kitchen": (299, 6999), "Fashion": (399, 4999),
    "Books": (249, 1499), "Sports": (149, 3499), "Beauty": (99, 2499),
}
DISCOUNTS = [0, 0, 0, 0, 0.05, 0.05, 0.10, 0.10, 0.15, 0.25]
CHANNELS = ["store"] * 6 + ["online"] * 3 + ["mobile"] * 1

rng = random.Random(SEED)


def daterange_random(start: date, end: date) -> date:
    return start + timedelta(days=rng.randint(0, (end - start).days))


def write_csv(path: Path, header, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(header)
        w.writerows(rows)
    print(f"  wrote {path.relative_to(ROOT.parent)}  ({len(rows):,} rows)")


# --------------------------------------------------------------------------- customers
def make_customers():
    customers = {}
    for i in range(1, 401):
        cid = f"C{i:04d}"
        first, last = rng.choice(FIRST), rng.choice(LAST)
        signup = daterange_random(date(2024, 1, 1), date(2025, 12, 31))
        customers[cid] = {
            "customer_id": cid,
            "full_name": f"{first} {last}",
            "email": f"{first.lower()}.{last.lower()}{i}@example.com",
            "city": rng.choice(ALL_CITIES),
            "segment": rng.choices(SEGMENTS, weights=[70, 20, 10])[0],
            "updated_at": f"{signup} 09:00:00",
        }
    return customers


def customer_row(c):
    return [c["customer_id"], c["full_name"], c["email"], c["city"], c["segment"], c["updated_at"]]


# --------------------------------------------------------------------------- products
def make_products():
    products = {}
    n = 1
    for cat, names in CATALOG.items():
        lo, hi = PRICE_RANGE[cat]
        for name in names:
            pid = f"P{n:03d}"
            products[pid] = {
                "product_id": pid, "product_name": name, "category": cat,
                "unit_price": round(rng.uniform(lo, hi) / 10) * 10 - 1,
                "is_active": "true", "updated_at": "2025-12-31 23:00:00",
            }
            n += 1
    return products


def product_row(p):
    return [p["product_id"], p["product_name"], p["category"], f'{p["unit_price"]:.2f}',
            p["is_active"], p["updated_at"]]


# --------------------------------------------------------------------------- stores
def make_stores():
    stores = {}
    n = 1
    for region, cities in CITIES.items():
        for city in cities[:3]:
            sid = f"S{n:02d}"
            stores[sid] = {"store_id": sid, "store_name": f"GrokMart {city}", "city": city,
                           "region": region, "updated_at": "2025-12-31 23:00:00"}
            n += 1
    return stores


def store_row(s):
    return [s["store_id"], s["store_name"], s["city"], s["region"], s["updated_at"]]


# --------------------------------------------------------------------------- sales
def make_sales(n, start, end, customer_ids, products, store_ids, first_id, min_date=None):
    rows = []
    active = [p for p in products.values() if p["is_active"] == "true"]
    for k in range(n):
        cid = rng.choice(customer_ids)
        lo = max(start, min_date.get(cid, start)) if min_date else start
        p = rng.choice(active)
        rows.append([
            first_id + k,
            daterange_random(lo, end).isoformat(),
            cid,
            p["product_id"],
            rng.choice(store_ids),
            rng.choice(CHANNELS),
            rng.choices([1, 2, 3, 4, 5], weights=[55, 25, 10, 6, 4])[0],
            f'{p["unit_price"]:.2f}',
            f"{rng.choice(DISCOUNTS):.2f}",
            "true" if rng.random() < 0.03 else "false",
        ])
    rows.sort(key=lambda r: (r[1], r[0]))
    return rows


SALES_HEADER = ["sale_id", "sale_date", "customer_id", "product_id", "store_id", "channel",
                "quantity", "unit_price", "discount_pct", "is_returned"]


# --------------------------------------------------------------------------- events
SEARCH_TERMS = ["earbuds", "air fryer", "running shoes", "sql book", "yoga mat", "sunscreen",
                "smart watch", "kurta", "power bank", "cricket bat"]
UTM = [None, None, {"source": "google", "medium": "cpc", "campaign": "summer_sale"},
       {"source": "instagram", "medium": "social", "campaign": "influencer_q2"},
       {"source": "newsletter", "medium": "email", "campaign": "weekly_digest"}]


def make_events(n, start, end, customer_ids, products, first_id):
    rows = []
    plist = list(products.values())
    for k in range(n):
        cid = rng.choice(customer_ids)
        ts = datetime.combine(daterange_random(start, end), datetime.min.time()) + timedelta(
            seconds=rng.randint(0, 86_399))
        etype = rng.choices(["page_view", "search", "add_to_cart", "checkout", "purchase"],
                            weights=[50, 20, 15, 8, 7])[0]
        os_ = rng.choices(["android", "ios", "web"], weights=[50, 25, 25])[0]
        payload = {
            "event_type": etype,
            "session_id": f"s-{rng.randint(10**7, 10**8 - 1)}",
            "device": {"os": os_, "app_version": None if os_ == "web" else rng.choice(["5.0.2", "5.1.0", "5.2.1"])},
        }
        if etype == "search":
            payload["search_query"] = rng.choice(SEARCH_TERMS)
            payload["results"] = rng.randint(0, 120)
        else:
            p = rng.choice(plist)
            payload["page"] = f"/product/{p['product_id']}"
            payload["product_id"] = p["product_id"]
        if etype in ("add_to_cart", "checkout", "purchase"):
            items = [{"product_id": q["product_id"], "qty": rng.randint(1, 3), "price": q["unit_price"]}
                     for q in rng.sample(plist, rng.randint(1, 3))]
            payload["cart"] = {"items": items, "total": round(sum(i["qty"] * i["price"] for i in items), 2)}
        utm = rng.choice(UTM)
        if utm:
            payload["utm"] = utm
        rows.append([first_id + k, cid, ts.isoformat(sep=" "), json.dumps(payload, separators=(",", ":"))])
    rows.sort(key=lambda r: r[2])
    return rows


EVENT_HEADER = ["event_id", "customer_id", "event_ts", "payload"]


def main():
    print("Generating GrokMart batches (seed=%d)" % SEED)
    customers, products, stores = make_customers(), make_products(), make_stores()
    store_ids = list(stores)

    # ------------------------------------------------------------- batch 1
    b1 = ROOT / "batch1"
    write_csv(b1 / "customers.csv", ["customer_id", "full_name", "email", "city", "segment", "updated_at"],
              [customer_row(c) for c in customers.values()])
    write_csv(b1 / "products.csv", ["product_id", "product_name", "category", "unit_price", "is_active", "updated_at"],
              [product_row(p) for p in products.values()])
    write_csv(b1 / "stores.csv", ["store_id", "store_name", "city", "region", "updated_at"],
              [store_row(s) for s in stores.values()])

    sales1 = make_sales(BATCH1_SALES, date(2026, 1, 1), date(2026, 4, 30), list(customers), products,
                        store_ids, first_id=1_000_001)
    # two bad rows in the initial load too
    sales1.append([1_999_901, "2026-02-14", "C0007", "P003", "S01", "store", -2, "999.00", "0.00", "false"])
    sales1.append([1_999_902, "2026-03-03", "C0042", "P404", "S02", "online", 1, "499.00", "0.00", "false"])
    write_csv(b1 / "sales.csv", SALES_HEADER, sales1)

    events1 = make_events(BATCH1_EVENTS, date(2026, 1, 1), date(2026, 4, 30), list(customers), products, 1)
    write_csv(b1 / "events.csv", EVENT_HEADER, events1)

    # ------------------------------------------------------------- batch 2
    b2 = ROOT / "batch2"
    cust_rows = []
    ids = sorted(customers)
    movers = rng.sample(ids, 40)
    for cid in movers[:30]:                       # city moves      -> SCD2
        c = customers[cid]
        c["city"] = rng.choice([x for x in ALL_CITIES if x != c["city"]])
        c["updated_at"] = "2026-05-01 06:00:00"
        cust_rows.append(customer_row(c))
    for cid in movers[30:]:                       # segment upgrade -> SCD2
        c = customers[cid]
        c["segment"] = "Corporate" if c["segment"] != "Corporate" else "Small Business"
        c["updated_at"] = "2026-05-01 06:00:00"
        cust_rows.append(customer_row(c))
    # a stale duplicate for the first mover (older timestamp, must lose DISTINCT ON)
    stale = list(cust_rows[0])
    stale[3], stale[5] = "Patna", "2026-04-15 06:00:00"
    cust_rows.append(stale)
    for cid in rng.sample([i for i in ids if i not in movers], 5):   # unchanged -> no-op
        cust_rows.append(customer_row(customers[cid]))
    new_customer_since = {}
    for i in range(401, 431):                     # brand-new customers
        cid = f"C{i:04d}"
        first, last = rng.choice(FIRST), rng.choice(LAST)
        joined = daterange_random(date(2026, 5, 1), date(2026, 5, 31))
        customers[cid] = {"customer_id": cid, "full_name": f"{first} {last}",
                          "email": f"{first.lower()}.{last.lower()}{i}@example.com",
                          "city": rng.choice(ALL_CITIES), "segment": "Consumer",
                          "updated_at": f"{joined} 09:00:00"}
        new_customer_since[cid] = joined
        cust_rows.append(customer_row(customers[cid]))
    write_csv(b2 / "customers.csv", ["customer_id", "full_name", "email", "city", "segment", "updated_at"], cust_rows)

    prod_rows = []
    for pid in rng.sample(sorted(products), 8):   # price changes -> SCD1 overwrite (+ audit trigger)
        p = products[pid]
        p["unit_price"] = round(p["unit_price"] * rng.choice([0.85, 0.9, 1.1, 1.2]) / 10) * 10 - 1
        p["updated_at"] = "2026-04-30 22:00:00"
        prod_rows.append(product_row(p))
    for pid in ["P013", "P047"]:                  # discontinued (soft delete)
        products[pid]["is_active"] = "false"
        products[pid]["updated_at"] = "2026-04-30 22:00:00"
        prod_rows.append(product_row(products[pid]))
    extra = [("P061", "Robot Vacuum", "Home & Kitchen", 15999), ("P062", "Fitness Band", "Electronics", 2499),
             ("P063", "Data Pipelines Pocket Guide", "Books", 899), ("P064", "Trail Running Shoes", "Fashion", 3999),
             ("P065", "Vitamin C Serum", "Beauty", 649)]
    for pid, name, cat, price in extra:
        products[pid] = {"product_id": pid, "product_name": name, "category": cat, "unit_price": price,
                         "is_active": "true", "updated_at": "2026-04-30 22:00:00"}
        prod_rows.append(product_row(products[pid]))
    write_csv(b2 / "products.csv", ["product_id", "product_name", "category", "unit_price", "is_active", "updated_at"], prod_rows)

    store_rows = []
    for sid, new_region in [("S06", "NORTH"), ("S11", "SOUTH")]:   # SCD3 region re-assignment
        stores[sid]["region"] = new_region
        stores[sid]["updated_at"] = "2026-05-01 00:00:00"
        store_rows.append(store_row(stores[sid]))
    stores["S13"] = {"store_id": "S13", "store_name": "GrokMart Surat", "city": "Surat", "region": "WEST",
                     "updated_at": "2026-05-01 00:00:00"}
    store_rows.append(store_row(stores["S13"]))
    write_csv(b2 / "stores.csv", ["store_id", "store_name", "city", "region", "updated_at"], store_rows)

    sales2 = make_sales(BATCH2_SALES, date(2026, 5, 1), date(2026, 6, 30), list(customers), products,
                        list(stores), first_id=2_000_001, min_date=new_customer_since)
    # late-arriving corrections: 50 April sales re-sent with a different quantity
    april = [r for r in sales1 if r[1].startswith("2026-04") and int(r[6]) > 0 and r[3] != "P404"]
    for r in rng.sample(april, 50):
        fixed = list(r)
        fixed[6] = int(fixed[6]) + 1
        sales2.append(fixed)
    # quarantine candidates
    for k in range(5):
        sales2.append([2_999_900 + k, "2026-05-1%d" % k, "C0100", "P010", "S03", "store", 0 - k, "1299.00", "0.00", "false"])
    for k in range(4):
        sales2.append([2_999_910 + k, "2026-06-0%d" % (k + 1), "C0200", "P999", "S04", "online", 1, "100.00", "0.00", "false"])
    for k in range(3):
        sales2.append([2_999_920 + k, "2026-06-1%d" % k, "", "P020", "S05", "store", 2, "500.00", "0.10", "false"])
    write_csv(b2 / "sales.csv", SALES_HEADER, sales2)

    events2 = make_events(BATCH2_EVENTS, date(2026, 5, 1), date(2026, 6, 30), list(customers), products, 100_001)
    events2 += rng.sample(events1, 200)          # replayed events from upstream retry
    events2.append([199_999, "C0001", "2026-06-15 10:00:00", '{"event_type":"page_view","device":'])  # truncated JSON
    write_csv(b2 / "events.csv", EVENT_HEADER, events2)
    print("Done.")


if __name__ == "__main__":
    main()
