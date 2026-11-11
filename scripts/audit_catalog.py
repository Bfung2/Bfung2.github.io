#!/usr/bin/env python3
"""Non-destructive Apex catalog integrity audit. Does not claim live Newegg verification."""
import argparse, collections, datetime, json, pathlib, sys

def audit(path):
    data=json.loads(path.read_text(encoding="utf-8"))
    records=[(section,p) for section in ("products","parts") for p in data.get(section,[])]
    by_id=collections.defaultdict(list)
    for section,p in records: by_id[str(p.get("id",""))].append((section,p))
    issues=[]
    def flag(kind,section,p,detail):
        issues.append({"issue":kind,"section":section,"id":p.get("id"),"name":p.get("name"),"detail":detail})
    for section,p in records:
        if not p.get("id") or not p.get("name"): flag("missing_identity",section,p,"ID or name missing")
        try:
            price=float(p.get("price"))
            if price<=0: raise ValueError()
        except (TypeError,ValueError): flag("invalid_price",section,p,"Missing/nonpositive price")
        baseline=p.get("neweggPrice")
        if baseline is None:
            flag("missing_newegg_baseline",section,p,"Requires exact live listing, seller and stock verification")
        else:
            try:
                if round(float(p["price"])-float(baseline),2)!=15.00:
                    flag("markup_mismatch",section,p,"Apex price does not equal Newegg baseline + $15")
            except (TypeError,ValueError,KeyError):
                flag("invalid_newegg_baseline",section,p,"Invalid baseline/price")
        if not p.get("sourceUrl"): flag("missing_source_url",section,p,"Exact Newegg listing URL missing")
        if not p.get("verifiedDate"): flag("missing_verification_date",section,p,"No recorded verification date")
        if not p.get("seller"): flag("missing_seller",section,p,"Direct Newegg seller not documented")
        if not p.get("stockStatus"): flag("missing_stock_status",section,p,"Stock status not documented")
        if not p.get("image"): flag("missing_image",section,p,"Image URL missing")
    for id,rows in by_id.items():
        if len(rows)>1:
            prices={str(p.get("price")) for _,p in rows}
            kind="duplicate_id_conflicting_prices" if len(prices)>1 else "duplicate_id"
            for section,p in rows: flag(kind,section,p,"ID occurs in "+str(len(rows))+" records; prices: "+", ".join(sorted(prices)))
    counts=dict(sorted(collections.Counter(i["issue"] for i in issues).items()))
    return {"generated_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "scope":"Static data.json only. NOT live Newegg seller, inventory, price, or image verification.",
            "total_entries":len(records),"section_counts":{k:len(data.get(k,[])) for k in ("products","parts")},
            "issue_counts":counts,"issues":issues}
def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--data",default="data.json")
    ap.add_argument("--output",default="catalog-audit-report.json")
    args=ap.parse_args()
    result=audit(pathlib.Path(args.data))
    pathlib.Path(args.output).write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"entries":result["total_entries"],"issues":result["issue_counts"],"report":args.output},indent=2))
if __name__=="__main__":main()
