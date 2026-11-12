import datetime
import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("apex_audit", ROOT / "scripts" / "audit_catalog.py")
audit_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit_module)

class Phase8AuditTests(unittest.TestCase):
    def test_mirrors_and_eligibility(self):
        today = datetime.datetime.now(datetime.timezone.utc).date()
        old = (today - datetime.timedelta(days=10)).isoformat()
        recent = today.isoformat()
        good = {
            "id":"mirror","name":"Same mirrored part","category":"CPU",
            "price":115,"neweggPrice":100,"sourceUrl":"https://www.newegg.com/p/N82E1",
            "verifiedDate":recent,"seller":"Newegg","stockStatus":"In Stock",
            "image":"https://example.test/img.png"
        }
        bad = {
            "id":"bad","name":"Bad seller",
            "category":"Graphics card","price":125,"neweggPrice":100,
            "sourceUrl":"https://not-newegg.example/p/evil",
            "verifiedDate":old,"seller":"Marketplace Seller",
            "stockStatus":"Backordered","image":"https://example.test/img.png"
        }
        conflict = dict(good,id="conflict")
        data = {
            "products":[good,bad,conflict],
            "parts":[dict(good),dict(conflict,price=130)]
        }
        with tempfile.TemporaryDirectory() as tmp:
            file=pathlib.Path(tmp)/"data.json"
            file.write_text(json.dumps(data),encoding="utf-8")
            result=audit_module.audit(file)
            by_id={}
            for issue in result["issues"]:
                by_id.setdefault(issue["id"],set()).add(issue["issue"])
            self.assertNotIn("duplicate_id",by_id.get("mirror",set()))
            self.assertNotIn("duplicate_id_conflicting_prices",by_id.get("mirror",set()))
            self.assertIn("duplicate_id_conflicting_prices",by_id["conflict"])
            self.assertIn("markup_mismatch",by_id["bad"])
            self.assertIn("invalid_source_url",by_id["bad"])
            self.assertIn("ineligible_seller",by_id["bad"])
            self.assertIn("ineligible_stock",by_id["bad"])
            self.assertIn("stale_verification",by_id["bad"])

    def test_report_does_not_claim_live_prices(self):
        with tempfile.TemporaryDirectory() as tmp:
            file=pathlib.Path(tmp)/"data.json"
            file.write_text(json.dumps({"products":[],"parts":[]}),encoding="utf-8")
            result=audit_module.audit(file)
            self.assertIn("NOT live Newegg",result["scope"])

if __name__=="__main__":
    unittest.main()
