#!/usr/bin/env python3
"""Non-destructive Apex catalog integrity audit. Does not claim live Newegg verification."""
import argparse, collections, csv, datetime, json, pathlib, sys, re, urllib.parse

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
        source=p.get("sourceUrl")
        if not source: flag("missing_source_url",section,p,"Exact Newegg listing URL missing")
        else:
            url=urllib.parse.urlparse(str(source))
            if url.scheme!="https" or (url.hostname or "").lower() not in ("newegg.com","www.newegg.com"):
                flag("invalid_source_url",section,p,"Source URL is not an HTTPS listing on Newegg")
        date=p.get("verifiedDate")
        if not date: flag("missing_verification_date",section,p,"No recorded verification date")
        else:
            try:
                verified=datetime.date.fromisoformat(str(date))
                age=(datetime.datetime.now(datetime.timezone.utc).date()-verified).days
                if age<0: flag("future_verification_date",section,p,"Recorded verification date is in the future")
                elif age>=7: flag("stale_verification",section,p,str(age)+" days since last recorded verification; recheck exact listing")
            except (TypeError,ValueError):
                flag("invalid_verification_date",section,p,"Invalid YYYY-MM-DD verification date")
        seller=str(p.get("seller") or "").strip().lower()
        if not seller: flag("missing_seller",section,p,"Direct Newegg seller not documented")
        elif seller not in ("newegg","newegg.com"):
            flag("ineligible_seller",section,p,"Stored seller is not Newegg; verify and unpublish if necessary")
        stock=str(p.get("stockStatus") or "").strip().lower()
        if not stock: flag("missing_stock_status",section,p,"Stock status not documented")
        elif re.search(r"out\s*of\s*stock|back[\s-]*order(?:ed)?|sold\s*out|unavailable|discontinued|price\s*verification\s*required|pre[\s-]*order",stock):
            flag("ineligible_stock",section,p,"Stored inventory status is not currently eligible for sale")
        if not p.get("image"): flag("missing_image",section,p,"Image URL missing")
    for id,rows in by_id.items():
        if len(rows)<2: continue
        sections={section for section,_ in rows}
        prices={str(p.get("price")) for _,p in rows}
        category_names={(str(p.get("category") or "").strip().lower(),str(p.get("name") or "").strip().lower()) for _,p in rows}
        if len(prices)>1:
            for section,p in rows: flag("duplicate_id_conflicting_prices",section,p,"ID occurs with different prices across "+", ".join(sorted(sections)))
        elif len(sections)!=len(rows):
            for section,p in rows: flag("duplicate_id_same_section",section,p,"ID appears more than once within the same catalog section")
        elif len(category_names)>1:
            for section,p in rows: flag("mirrored_identity_conflict",section,p,"Products/parts copies have conflicting names or categories")
        # A single matching ID in products and parts is an intentional storefront mirror,
        # not automatically a duplicate catalog error.
    counts=dict(sorted(collections.Counter(i["issue"] for i in issues).items()))
    return {"generated_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "scope":"Static data.json only. NOT live Newegg seller, inventory, price, or image verification.",
            "total_entries":len(records),"section_counts":{k:len(data.get(k,[])) for k in ("products","parts")},
            "issue_counts":counts,"issues":issues}
def review_queue(data_path, report, output):
    """One row per SKU, prioritizing active listings needing documentary evidence.
    Missing metadata is a review task, never proof that an item is incompatible.
    """
    data=json.loads(data_path.read_text(encoding="utf-8"))
    grouped=collections.defaultdict(list)
    for section in ("products","parts"):
        for p in data.get(section,[]): grouped[str(p.get("id",""))].append((section,p))
    issues=collections.defaultdict(set)
    for issue in report["issues"]: issues[str(issue["id"])].add(issue["issue"])
    required={"Graphics card":["lengthMm","requiredPowerConnectors","recommendedPsuWatts"],
              "Case":["caseFormFactors","maxGpuLengthMm","maxCoolerHeightMm","supportedPSUFormFactors"],
              "Motherboard":["socket","memType","formFactor"],
              "Memory":["memType","heightMm"],"Power supply":["watts","formFactor","gpuPowerConnectors"],
              "CPU":["socket","tdp"]}
    rows=[]
    for sku,records in grouped.items():
        p=records[0][1];active=any(x.get("active",True) is not False for _,x in records)
        missing=set()
        for _,x in records:
            for field in required.get(x.get("category"),[]):
                if x.get(field) in (None,""): missing.add(field)
            if x.get("category")=="CPU cooler":
                if not x.get("supportedSockets") and not x.get("socket"): missing.add("supportedSockets")
                # Liquid and air coolers need different clearance evidence; do not guess the type.
                if not x.get("heightMm") and not x.get("radiatorSizeMm"): missing.add("air height or liquid radiator dimensions/type")
        found=issues[sku]-{"duplicate_id"}
        if not found and not missing: continue
        rows.append({"priority":1 if active and found else 2 if active else 3,"active":active,"id":sku,"name":p.get("name",""),"category":p.get("category",""),"sections":";".join(x for x,_ in records),"catalog_review":";".join(sorted(found)),"fit_review":";".join(sorted(missing)),"source_url":p.get("sourceUrl","")})
    rows.sort(key=lambda x:(x["priority"],x["category"],x["name"]))
    with output.open("w",newline="",encoding="utf-8") as f:
        writer=csv.DictWriter(f,fieldnames=["priority","active","id","name","category","sections","catalog_review","fit_review","source_url"])
        writer.writeheader();writer.writerows(rows)
    return {"review_skus":len(rows),"active_review_skus":sum(r["active"] for r in rows),"queue":str(output)}

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--data",default="data.json")
    ap.add_argument("--output",default="catalog-audit-report.json")
    ap.add_argument("--review-queue",help="Optional CSV of grouped SKU catalog/fit review tasks")
    args=ap.parse_args()
    result=audit(pathlib.Path(args.data))
    pathlib.Path(args.output).write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    summary={"entries":result["total_entries"],"issues":result["issue_counts"],"report":args.output}
    if args.review_queue: summary.update(review_queue(pathlib.Path(args.data),result,pathlib.Path(args.review_queue)))
    print(json.dumps(summary,indent=2))
if __name__=="__main__":main()
