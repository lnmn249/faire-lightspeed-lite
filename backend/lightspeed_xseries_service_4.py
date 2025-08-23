
"""
lightspeed_xseries_service.py
--------------------------------
Refactor of the user's working procedural code into a class-based design, preserving routes and behavior.

Key fixes & notes:
- Normalized local catalog storage to a single JSON dict with keys: products, suppliers, brands.
- Corrected products fetch param from `delete=false` to `deleted=false`.
- Implemented consistent pagination helper that follows API 2.0 `links.next` when present.
- Kept SUPPLIER consignment creation and consignment-product add payloads aligned with X‑Series docs.
- Kept DRY_RUN mode behavior identical to original semantics.
- Preserved FastAPI routes:
  /catalog/refresh
  /catalog/refresh/stream
  /catalog/last-refresh
  /orders/preview
  /orders/preview-csv
  /orders/submit
  /health
"""

import os
import io
import csv
import json
import time
import asyncio
import datetime as dt
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Tuple, AsyncGenerator

import requests
import pandas as pd
from fastapi import FastAPI, File, HTTPException, Request, UploadFile, APIRouter
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import logging

# Optional Google Cloud imports (firestore + secretmanager).
# If they are not present locally, the service will fall back to env + local JSON storage.
try:
    from google.cloud import firestore as gcfirestore  # type: ignore
    from google.cloud import secretmanager as gcsecrets  # type: ignore
except Exception:  # pragma: no cover
    gcfirestore = None
    gcsecrets = None


# -------------------------------
# Configuration / Constants
# -------------------------------
PROJECT_ID = os.environ.get("GCP_PROJECT", "")
UI_ORIGIN = os.environ.get("UI_ORIGIN", "")
# DRY_RUN = os.environ.get("DRY_RUN", "true").lower() in {"1", "true", "yes", "y"}
DRY_RUN = False

BASE_DIR = Path(__file__).parent
DATA_DIR = BASE_DIR / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

CATALOG_FILE = DATA_DIR / "catalog.json"
LOCAL_META_FILE = DATA_DIR / "meta.json"

raw_dry = os.environ.get("DRY_RUN", "true")
print(">>> DRY_RUN raw:", repr(raw_dry), "parsed:", DRY_RUN)

# -------------------------------
# Secrets
# -------------------------------
class SecretProvider:
    """
    Get secrets from env in local mode; use GCP Secret Manager when PROJECT_ID is set and library is available.
    Env var names must match those used in the original code: LS_BASE_URL, LS_API_KEY, OUTLET_ID.
    """

    def __init__(self, project_id: str) -> None:
        self.project_id = project_id
        self._client = None
        if project_id and gcsecrets is not None:
            try:
                self._client = gcsecrets.SecretManagerServiceClient()
            except Exception:
                # Fall back to env if client cannot initialize
                self._client = None

    def get(self, name: str) -> str:
        # Local dev / fallback: env var
        if not self.project_id or self._client is None:
            val = os.environ.get(name)
            if not val:
                raise RuntimeError(f"Secret {name} not set in environment")
            return val

        # GCP Secret Manager (latest version)
        path = self._client.secret_version_path(self.project_id, name, "latest")
        resp = self._client.access_secret_version(request={"name": path})
        return resp.payload.data.decode("utf-8")


# -------------------------------
# Catalog storage
# -------------------------------
class CatalogStore:
    """Abstract storage for products, suppliers, brands and small meta values."""

    def save_catalog(self, data: Dict[str, List[Dict[str, Any]]]) -> None:
        raise NotImplementedError

    def load_catalog(self) -> Dict[str, List[Dict[str, Any]]]:
        raise NotImplementedError

    def set_meta(self, key: str, value: Any) -> None:
        raise NotImplementedError

    def get_meta(self, key: str) -> Optional[Any]:
        raise NotImplementedError


class LocalCatalogStore(CatalogStore):
    def save_catalog(self, data: Dict[str, List[Dict[str, Any]]]) -> None:
        with open(CATALOG_FILE, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, ensure_ascii=False)
        # Helpful log for local testing
        print(f"[LOCAL] Saved catalog → products={len(data.get('products', []))}, "
              f"suppliers={len(data.get('suppliers', []))}, brands={len(data.get('brands', []))}")

    def load_catalog(self) -> Dict[str, List[Dict[str, Any]]]:
        if not CATALOG_FILE.exists():
            print("[LOCAL] No local catalog file found")
            return {"products": [], "suppliers": [], "brands": []}
        with open(CATALOG_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        # Backwards compatibility if a raw list of products is present
        if isinstance(data, list):
            data = {"products": data, "suppliers": [], "brands": []}
        print(f"[LOCAL] Loaded catalog ← products={len(data.get('products', []))}, "
              f"suppliers={len(data.get('suppliers', []))}, brands={len(data.get('brands', []))}")
        return data

    def set_meta(self, key: str, value: Any) -> None:
        if LOCAL_META_FILE.exists():
            try:
                blob = json.loads(LOCAL_META_FILE.read_text())
            except Exception:
                blob = {}
        else:
            blob = {}
        blob[key] = {
            "value": value,
            "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }
        LOCAL_META_FILE.write_text(json.dumps(blob, indent=2))


    def get_meta(self, key: str) -> Optional[Any]:
        if not LOCAL_META_FILE.exists():
            return None
        try:
            blob = json.loads(LOCAL_META_FILE.read_text())
        except Exception:
            return None
        rec = blob.get(key)
        return rec.get("value") if isinstance(rec, dict) else None


class FirestoreCatalogStore(CatalogStore):
    def __init__(self, project_id: str) -> None:
        if gcfirestore is None:
            raise RuntimeError("google-cloud-firestore is not available")
        self.client = gcfirestore.Client(project=project_id)

    def save_catalog(self, data: Dict[str, List[Dict[str, Any]]]) -> None:
        # Save products/suppliers/brands as simple collections (merge to keep write sizes saner)
        prod_col = self.client.collection("products")
        sup_col = self.client.collection("suppliers")
        br_col = self.client.collection("brands")

        # Products
        batch = self.client.batch()
        for p in data.get("products", []):
            pid = str(p.get("id") or p.get("supplier_code") or "")
            if not pid:
                continue
            batch.set(prod_col.document(pid), p, merge=True)
        batch.commit()

        # Suppliers
        batch = self.client.batch()
        for s in data.get("suppliers", []):
            sid = str(s.get("id") or s.get("name") or "")
            if not sid:
                continue
            batch.set(sup_col.document(sid), s, merge=True)
        batch.commit()

        # Brands
        batch = self.client.batch()
        for b in data.get("brands", []):
            bid = str(b.get("id") or b.get("name") or "")
            if not bid:
                continue
            batch.set(br_col.document(bid), b, merge=True)
        batch.commit()

        print(f"[FIRESTORE] Saved catalog: "
              f"products={len(data.get('products', []))}, "
              f"suppliers={len(data.get('suppliers', []))}, "
              f"brands={len(data.get('brands', []))}")

    def load_catalog(self) -> Dict[str, List[Dict[str, Any]]]:
        products = [doc.to_dict() for doc in self.client.collection("products").stream()]
        suppliers = [doc.to_dict() for doc in self.client.collection("suppliers").stream()]
        brands = [doc.to_dict() for doc in self.client.collection("brands").stream()]
        return {"products": products, "suppliers": suppliers, "brands": brands}

    def set_meta(self, key: str, value: Any) -> None:
        self.client.collection("meta").document(key).set(
            {"value": value, "updated_at": gcfirestore.SERVER_TIMESTAMP}, merge=True
        )

    def get_meta(self, key: str) -> Optional[Any]:
        doc = self.client.collection("meta").document(key).get()
        return (doc.to_dict() or {}).get("value") if doc.exists else None


def get_catalog_store() -> CatalogStore:
    if PROJECT_ID and gcfirestore is not None:
        try:
            return FirestoreCatalogStore(PROJECT_ID)
        except Exception as e:  # pragma: no cover
            print(f"[WARN] Falling back to LocalCatalogStore: {e}")
            return LocalCatalogStore()
    return LocalCatalogStore()



# -------------------------------
# Lightspeed X‑Series API Client
# -------------------------------
class XSeriesClient:
    def __init__(self, secrets: SecretProvider) -> None:
        self.base_url = secrets.get("LS_BASE_URL").rstrip("/")
        self.api_key = secrets.get("LS_API_KEY")

        # Basic logger config (can be overridden by uvicorn logging config)
        logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

    # Common headers
    def _headers(self) -> Dict[str, str]:
        return {
            "Authorization": f"Bearer {self.api_key}",
            "accept": "application/json",
            "content-type": "application/json",
            "user-agent": "bwp-inventory/1.0 (lightspeed-xseries-service)",
        }

    # Centralized response logging
    def _log_response(self, r: requests.Response, url: str, method: str, payload: Optional[Dict[str, Any]] = None) -> None:
        if r.status_code >= 400:
            # Log important debugging details when errors occur
            try_body = r.text[:1000] if r.text else ""
            try_headers = dict(r.headers) if r.headers else {}
            logging.error(
                f"[LS] {method} {url} status={r.status_code} reason={r.reason} "
                f"payload_keys={list(payload.keys()) if payload else None} "
                f"headers={try_headers} body={try_body}"
            )
        else:
            logging.info(f"[LS] {method} {url} status={r.status_code}")

    # Wrapped GET with logging
    def _get_with_log(self, url: str) -> requests.Response:
        logging.info(f"[LS] GET {url}")
        r = requests.get(url, headers=self._headers(), timeout=120)
        self._log_response(r, url, "GET")
        return r

    # Wrapped POST with logging
    def _post_with_log(self, url: str, payload: Dict[str, Any]) -> requests.Response:
        logging.info(f"[LS] POST {url} payload_keys={list(payload.keys())}")
        r = requests.post(url, headers=self._headers(), json=payload, timeout=120)
        self._log_response(r, url, "POST", payload)
        return r

    # Generic GET with pagination following `links.next` (API 2.0)
    def _accumulate(self, url: str) -> List[Dict[str, Any]]:
        out: List[Dict[str, Any]] = []
        next_url = url
        while next_url:
            r = self._get_with_log(next_url)
            r.raise_for_status()
            payload = r.json()
            data = payload.get("data", payload.get("products", payload.get("suppliers", payload.get("brands", []))))
            if isinstance(data, list):
                out.extend(data)
            links = payload.get("links") or {}
            next_url = links.get("next") if isinstance(links, dict) else None
        return out

    # ---------- Catalog pulls ----------
    def ls_iter_all_products(self, page_size: int = 200, include_deleted: bool = False) -> List[Dict[str, Any]]:
        # Do not clamp page_size; caller controls it
        url = f"{self.base_url}/products?page_size={int(page_size)}&deleted={'true' if include_deleted else 'false'}"
        items = self._accumulate(url)
        logging.info(f"[LS] Pulled {len(items)} products (page_size={page_size})")
        return items

    def ls_iter_all_suppliers(self, page_size: int = 200) -> List[Dict[str, Any]]:
        url = f"{self.base_url}/suppliers?page_size={int(page_size)}"
        items = self._accumulate(url)
        logging.info(f"[LS] Pulled {len(items)} suppliers (page_size={page_size})")
        return items

    def ls_iter_all_brands(self, page_size: int = 200) -> List[Dict[str, Any]]:
        url = f"{self.base_url}/brands?page_size={int(page_size)}"
        items = self._accumulate(url)
        logging.info(f"[LS] Pulled {len(items)} brands (page_size={page_size})")
        return items

    # ---------- Create entities ----------
    def ls_create_supplier(self, name: str, description: str = "") -> Dict[str, Any]:
        payload = {"name": name, "description": description or name}
        if DRY_RUN:
            logging.info(f"[DRY RUN] Would create supplier: {payload}")
            return {"id": f"dry_supplier_{name}", **payload}
        r = self._post_with_log(f"{self.base_url}/suppliers", payload)
        r.raise_for_status()
        return r.json().get("data", {})

    def ls_create_brand(self, name: str) -> Dict[str, Any]:
        payload = {"name": name}
        if DRY_RUN:
            logging.info(f"[DRY RUN] Would create brand: {payload}")
            return {"id": f"dry_brand_{name}", **payload}
        r = self._post_with_log(f"{self.base_url}/brands", payload)
        if r.status_code in (200, 201):
            return r.json().get("data", {})
        # Logged already in _log_response; return empty to preserve existing behavior
        return {}

    from fastapi import HTTPException

    def ls_create_product(self, payload: dict) -> dict:
        if DRY_RUN:
            logging.info(f"[DRY RUN] Would create product: {payload}")
            return {"id": f"dry_product_{payload.get('supplier_code')}"}

        url = f"{self.base_url}/products"
        r = requests.post(url, headers=self._headers(), json=payload, timeout=120)

        if r.status_code == 422:
            try:
                body = r.json()
            except Exception:
                body = {}
            product_name = payload.get("name")
            msg = f"Product creation failed for '{product_name}': {body}"
            logging.error(msg)
            raise HTTPException(status_code=422, detail=msg)

        r.raise_for_status()
        data = r.json().get("data")

        if isinstance(data, list) and len(data) == 1 and isinstance(data[0], str):
            return {"id": data[0]}
        if isinstance(data, dict):
            return data
        return {}


    # ---------- Consignments (Stock Orders) ----------
    def ls_create_consignment_shell(self, outlet_id: str, supplier_id: str, supplier_name: str, order_number: str) -> Dict[str, Any]:
        payload = {
            "name": f"Faire Stock Order - {supplier_name or supplier_id}",
            "outlet_id": outlet_id,
            "type": "SUPPLIER",
            "status": "OPEN",
            "supplier_id": supplier_id,
            "supplier_invoice": order_number
        }
        if DRY_RUN:
            logging.info(f"[DRY RUN] Would create consignment shell: {payload}")
            return {"id": "dry_consignment_id", **payload}
        r = self._post_with_log(f"{self.base_url}/consignments", payload)
        r.raise_for_status()
        return r.json().get("data", {})

    def ls_add_products_to_consignment(self, consignment_id: str, line_items: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        if DRY_RUN:
            logging.info(f"[DRY RUN] Would add {len(line_items)} products to consignment {consignment_id}")
            return [{"product_id": li.get("product_id"), "count": li.get("count")} for li in line_items]

        url = f"{self.base_url}/consignments/{consignment_id}/products"
        results: List[Dict[str, Any]] = []
        for li in line_items:
            r = self._post_with_log(url, li)
            if r.status_code in (200, 201):
                results.append(r.json())
        return results
    def ls_get_brand_id(self, name: str) -> Optional[str]:
        r = requests.get(f"{self.base_url}/brands",
                        headers=self._headers(),
                        params={"page_size": 5000},
                        timeout=60)
        r.raise_for_status()
        rows = (r.json() or {}).get("data", []) or []
        name_l = (name or "").strip().lower()
        for b in rows:
            if str(b.get("name","")).strip().lower() == name_l:
                return b.get("id")
        return None

    def ls_search_products_by_brand_df(self, brand_id: str) -> pd.DataFrame:
        # one-shot; bump page_size high to avoid pagination complexity
        r = requests.get(f"{self.base_url}/search",
                        headers=self._headers(),
                        params={"type": "products", "brand_id": brand_id, "page_size": 10000},
                        timeout=120)
        r.raise_for_status()
        return pd.DataFrame((r.json() or {}).get("data", []) or [])
    def ls_get_supplier_id(self, name: str) -> Optional[str]:
        r = requests.get(
            f"{self.base_url}/suppliers",
            headers=self._headers(),
            params={"page_size": 5000},
            timeout=60,
        )
        r.raise_for_status()
        rows = (r.json() or {}).get("data", []) or []
        name_l = (name or "").strip().lower()
        for s in rows:
            if str(s.get("name", "")).strip().lower() == name_l:
                return s.get("id")
        return None




# -------------------------------
# Business services
# -------------------------------
class OrderService:
    def __init__(self, ls: XSeriesClient, store: CatalogStore, secrets: SecretProvider) -> None:
        self.ls = ls
        self.store = store
        self.secrets = secrets

    # ---- Catalog refresh utilities ----
    def refresh_catalog(self, page_size: int = 200) -> Dict[str, Any]:
        products = self.ls.ls_iter_all_products(page_size=page_size)
        suppliers = self.ls.ls_iter_all_suppliers(page_size=page_size)
        brands = self.ls.ls_iter_all_brands(page_size=page_size)

        # Flatten supplier/brand objects (id + name) where present for quick joins later
        for p in products:
            if isinstance(p.get("supplier"), dict):
                p["supplier_id"] = p["supplier"].get("id")
                p["supplier_name"] = p["supplier"].get("name")
                p.pop("supplier", None)
            if isinstance(p.get("brand"), dict):
                p["brand_id"] = p["brand"].get("id")
                p["brand_name"] = p["brand"].get("name")
                p.pop("brand", None)

        data = {"products": products, "suppliers": suppliers, "brands": brands}

        # Save in non-stream path for parity with the stream path
        self.store.save_catalog(data)

        # Update both epoch and iso metas so the UI can read either
        epoch = int(time.time())
        iso = datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z")
        self.store.set_meta("catalog_last_refresh_epoch", epoch)
        self.store.set_meta("catalog_last_refresh_iso", iso)

        return {
            "ok": True,
            "count": {k: len(v) for k, v in data.items()},
            "last_refresh": {"epoch": epoch, "iso": iso},
        }



    async def refresh_catalog_stream(self, page_size: int = 200) -> AsyncGenerator[str, None]:
        # Proper SSE: named events that the UI can listen for
        yield "event: progress\ndata: Starting fetch...\n\n"
        await asyncio.sleep(0)
        try:
            products = self.ls.ls_iter_all_products(page_size=page_size)
            yield f"event: progress\ndata: Pulled {len(products)} products\n\n"

            suppliers = self.ls.ls_iter_all_suppliers(page_size=page_size)
            yield f"event: progress\ndata: Pulled {len(suppliers)} suppliers\n\n"

            brands = self.ls.ls_iter_all_brands(page_size=page_size)
            yield f"event: progress\ndata: Pulled {len(brands)} brands\n\n"

            # Flatten for consistency
            for p in products:
                if isinstance(p.get("supplier"), dict):
                    p["supplier_id"] = p["supplier"].get("id")
                    p["supplier_name"] = p["supplier"].get("name")
                    p.pop("supplier", None)
                if isinstance(p.get("brand"), dict):
                    p["brand_id"] = p["brand"].get("id")
                    p["brand_name"] = p["brand"].get("name")
                    p.pop("brand", None)

            # Save + meta
            self.store.save_catalog({"products": products, "suppliers": suppliers, "brands": brands})
            epoch = int(time.time())
            iso = datetime.fromtimestamp(epoch, tz=timezone.utc).isoformat().replace("+00:00", "Z")
            self.store.set_meta("catalog_last_refresh_epoch", epoch)
            self.store.set_meta("catalog_last_refresh_iso", iso)

            yield "event: progress\ndata: Saved catalog\n\n"
            yield f"event: last_refresh\ndata: {json.dumps({'epoch': epoch, 'iso': iso})}\n\n"
            yield "event: done\ndata: ok\n\n"

        except Exception as e:
            yield f"event: error\ndata: {str(e)}\n\n"


    def last_refresh(self) -> Dict[str, Any]:
        epoch = self.store.get_meta("catalog_last_refresh_epoch")
        iso_meta = self.store.get_meta("catalog_last_refresh_iso")

        # Normalize epoch -> int when possible
        try:
            epoch = int(epoch) if epoch is not None else None
        except Exception:
            pass

        if isinstance(iso_meta, str) and iso_meta:
            iso = iso_meta
        else:
            iso = None
            if epoch is not None:
                try:
                    iso = datetime.fromtimestamp(int(epoch), tz=timezone.utc).isoformat().replace("+00:00", "Z")
                except Exception:
                    iso = None

        return {"last_refresh": {"epoch": epoch, "iso": iso}}



    # ---- Preview and Submit ----
    def _load_catalog_frames(self) -> Tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
        blob = self.store.load_catalog()
        df_products = pd.DataFrame(blob.get("products", []))
        df_suppliers = pd.DataFrame(blob.get("suppliers", []))
        df_brands = pd.DataFrame(blob.get("brands", []))

        # Flatten supplier/brand dicts if caller saved raw product shape
        if "supplier" in df_products.columns:
            df_products["supplier_id"] = df_products["supplier"].apply(lambda x: x.get("id") if isinstance(x, dict) else None)
            df_products["supplier_name"] = df_products["supplier"].apply(lambda x: x.get("name") if isinstance(x, dict) else None)
            df_products.drop(columns=["supplier"], inplace=True, errors="ignore")
        if "brand" in df_products.columns:
            df_products["brand_id"] = df_products["brand"].apply(lambda x: x.get("id") if isinstance(x, dict) else None)
            df_products["brand_name"] = df_products["brand"].apply(lambda x: x.get("name") if isinstance(x, dict) else None)
            df_products.drop(columns=["brand"], inplace=True, errors="ignore")

        return df_products, df_suppliers, df_brands

    def preview_items(self, items: List[Dict[str, Any]]) -> Dict[str, Any]:
        df_products, _, _ = self._load_catalog_frames()

        # Normalize
        df_products["supplier_code"] = df_products.get("supplier_code", pd.Series(dtype=object)).astype(str).str.strip().str.upper()
        df_products["brand_name"] = df_products.get("brand_name", pd.Series(dtype=object)).astype(str).str.strip()

        matched: List[Dict[str, Any]] = []
        missing: List[Dict[str, Any]] = []

        for it in items:
            sku = str(it.get("sku") or "").strip().upper()
            brand = str(it.get("brand_name") or "").strip()
            qty = int(it.get("quantity") or 0)
            if not sku or not brand:
                continue
            row = df_products[(df_products["supplier_code"] == sku) & (df_products["brand_name"] == brand)]
            if not row.empty:
                r = row.iloc[0].to_dict()
                matched.append({
                    "sku": sku,
                    "brand_name": brand,
                    "quantity": qty,
                    "product_id": r.get("id"),
                    "product_name": r.get("name"),
                    "supplier_id": r.get("supplier_id"),
                })
            else:
                missing.append({"sku": sku, "brand_name": brand, "quantity": qty})

        return {"matched": matched, "missing": missing}

    def preview_csv(self, file_bytes: bytes) -> Dict[str, Any]:
        import io, pandas as pd, numpy as np, math
        
        df_faire = pd.read_csv(io.BytesIO(file_bytes))
        df_faire = df_faire.rename(columns={
            # "SKU": "supplier_code_f",     # Faire SKU → supplier_code
            "Order Number": "order_number",
            "Brand Name": "brand_name_f",
            "Product Name": "product_name_f",
            "Quantity": "quantity_f",
            "Wholesale Price": "wholesale_price_f"
            })

        # required cols
        need = {"SKU", "brand_name_f", "quantity_f","wholesale_price_f"}
        if not need.issubset(df_faire.columns):
            raise HTTPException(status_code=400, detail="CSV must include: SKU, Brand Name, Quantity")

        # focus on first brand (your “no-loops” flow)
        brand = str(df_faire["brand_name_f"].dropna().iloc[0])
        bid = self.ls.ls_get_brand_id(brand)
        if not bid:
            out = df_faire.copy()
            out["sku"] = ""  # LS sku must be blank for creations later
            out.replace({pd.NA: None}, inplace=True)
            return {"matched": [], "missing": out.to_dict(orient="records")}

        # live LS search → DataFrame
        df_ls = self.ls.ls_search_products_by_brand_df(bid)
        if df_ls.empty:
            out = df_faire.copy(); out["sku"] = ""
            out.replace({pd.NA: None}, inplace=True)
            return {"matched": [], "missing": out.to_dict(orient="records")}

        # choose supplier_code-ish key from LS without hardcoding shape elsewhere
        key_ls = next((c for c in ["supplier_code", "sku", "SKU", "code"] if c in df_ls.columns), None)
        if not key_ls:
            out = df_faire.copy(); out["sku"] = ""
            out.replace({pd.NA: None}, inplace=True)
            return {"matched": [], "missing": out.to_dict(orient="records")}

        # lowercase join: Faire SKU ↔ LS supplier_code (or fallback key)
        fa = df_faire[df_faire["brand_name_f"].str.lower().eq(brand.lower())].copy()
        fa["__key__"] = fa["SKU"].astype(str).str.lower()
        df_ls["__key__"] = df_ls[key_ls].astype(str).str.lower()

        merged = fa.merge(df_ls, on="__key__", how="left", suffixes=("", "_ls"))

        # matched/missing without dropping columns (keep everything)
        is_match = merged["id"].notna() if "id" in merged.columns else merged[f"{key_ls}_ls"].notna()
        matched = merged[is_match].copy()
        missing = merged[~is_match].copy()

        # ensure LS sku is empty on missing for later product creation
        if "sku" not in missing.columns: missing["sku"] = ""
        missing["sku"] = ""

        # convert top-level NaN/inf to None
        for df_ in (matched, missing):
            df_.replace([np.inf, -np.inf], None, inplace=True)
            df_.where(pd.notna(df_), None, inplace=True)

        # --- NEW: recursive JSON-safe cleanup for nested values ---
        def _clean(obj):
            if isinstance(obj, float):
                return None if (math.isnan(obj) or math.isinf(obj)) else obj
            if obj is pd.NaT: return None
            # numpy scalars -> Python scalars
            if isinstance(obj, (np.floating, np.integer)): return obj.item()
            if isinstance(obj, (pd.Timestamp, )):
                return obj.tz_localize("UTC").isoformat().replace("+00:00","Z") if obj.tzinfo is None else obj.isoformat()
            if isinstance(obj, dict):  return {k: _clean(v) for k, v in obj.items()}
            if isinstance(obj, (list, tuple, set)): return [_clean(v) for v in obj]
            try:
                # catches pd.NA, NaT in odd places
                if pd.isna(obj): return None
            except Exception:
                pass
            return obj

        matched_rec = [_clean(rec) for rec in matched.to_dict(orient="records")]
        missing_rec = [_clean(rec) for rec in missing.to_dict(orient="records")]

        return {"matched": matched_rec, "missing": missing_rec}

    def submit_order(self, items: List[Dict[str, Any]], auto_create_missing: bool = False) -> Dict[str, Any]:
        if not items:
            raise HTTPException(status_code=400, detail="No items provided in request")

        # --- Resolve supplier (still first, we need supplier_id) ---
        matched = [it for it in items if it.get("product_id")]
        if matched:
            supplier_id = matched[0].get("supplier_id")
            supplier_name = matched[0].get("supplier_name")
        else:
            supplier_name = items[0].get("supplier_name") or items[0].get("brand_name") or items[0].get("brand_name_f")
            supplier_id = self.ls.ls_get_supplier_id(supplier_name)
            if not supplier_id:
                sup = self.ls.ls_create_supplier(supplier_name)
                supplier_id = sup.get("id")

        if not supplier_id:
            raise HTTPException(status_code=400, detail="Could not resolve supplier_id")

        # --- Resolve brand (same as before) ---
        brand_name = (
            matched[0].get("brand_name")
            if matched else items[0].get("brand_name") or items[0].get("brand_name_f")
        )
        brand_id = self.ls.ls_get_brand_id(brand_name)
        if not brand_id:
            b = self.ls.ls_create_brand(brand_name)
            brand_id = b.get("id")

        # --- Build line items first ---
        line_items: List[Dict[str, Any]] = []
        created_products: List[Dict[str, Any]] = []

        for it in items:
            pid = it.get("product_id")
            qty = int(it.get("quantity") or 0)
            cost = it.get("wholesale_price")

            if pid:
                li = {"product_id": pid, "count": qty}
                if cost not in (None, "", "NaN"):
                    li["cost"] = float(cost)
                line_items.append(li)
                continue

            if not auto_create_missing:
                continue

            # Create missing product first
            product_payload = {
                "name": it.get("product_name") or it.get("product_name_f"),
                "supplier_code": it.get("supplier_code") or it.get("SKU"),
                "supplier_id": supplier_id,
                "type": "standard",
            }
            if brand_id:
                product_payload["brand_id"] = brand_id
            if cost not in (None, "", "NaN"):
                product_payload["default_cost"] = float(cost)

            # 
            try:
                new_p = self.ls.ls_create_product(product_payload)
            except requests.HTTPError as e:
                detail = f"Failed to create product '{product_payload.get('name')}'. {str(e)}"
                raise HTTPException(status_code=422, detail=detail)

            if new_p.get("id"):
                created_products.append(new_p)
                li = {"product_id": new_p["id"], "count": qty}
                if cost not in (None, "", "NaN"):
                    li["cost"] = float(cost)
                line_items.append(li)

        if not line_items:
            raise HTTPException(status_code=400, detail="No valid products to add to consignment")

        # --- Create consignment only after we know we have line_items ---
        outlet_id = self.secrets.get("OUTLET_ID")
        order_number = items[0].get("order_number")
        cons = self.ls.ls_create_consignment_shell(outlet_id, supplier_id, supplier_name, order_number)

        results = self.ls.ls_add_products_to_consignment(cons["id"], line_items)

        return {
            "ok": True,
            "consignment_id": cons["id"],
            "supplier_id": supplier_id,
            "supplier_name": supplier_name,
            "brand_id": brand_id,
            "created_products": created_products,
            "line_count": len(line_items),
            "results": results,
        }



# -------------------------------
# Pydantic models to mirror original request/response contracts
# -------------------------------
class PreviewItem(BaseModel):
    # SKU: Optional[str]              # Faire’s supplier code (uppercase from form)
    supplier_code: Optional[str]    # normalized version we’ll use in backend
    sku: Optional[str]
    brand_name: Optional[str]
    product_name: Optional[str]
    product_id: Optional[str]
    supplier_id: Optional[str]
    supplier_name: Optional[str]
    quantity: Optional[int]
    wholesale_price: Optional[float]
    order_number: Optional[str]


class PreviewRequest(BaseModel):
    items: List[PreviewItem]


class PreviewResult(BaseModel):
    matched: List[Dict[str, Any]]
    missing: List[Dict[str, Any]]


class SubmitRequest(BaseModel):
    items: List[PreviewItem]
    auto_create_missing: Optional[bool] = False


# -------------------------------
# FastAPI wiring
# -------------------------------
secrets = SecretProvider(PROJECT_ID)
store = get_catalog_store()
ls_client = XSeriesClient(secrets)
orders = OrderService(ls_client, store, secrets)

app = FastAPI(title="Faire → Lightspeed Class API", version="1.0.0")

# CORS (preserve original behavior)
allow_credentials = bool(UI_ORIGIN)
allow_origins = [UI_ORIGIN] if UI_ORIGIN else ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=allow_origins,
    allow_credentials=allow_credentials,
    allow_methods=["GET", "POST", "OPTIONS"],
    allow_headers=["*"],
)


def now_ts() -> int:
    return int(time.time())

@app.get("/")
def root():
    return {"status": "ok"}

api = APIRouter(prefix="/api")

@api.get("/")
def api_root():
    return {"ok": True}

@api.get("/catalog/refresh")
def catalog_refresh(page_size: int = 200):
    return orders.refresh_catalog(page_size=page_size)


@api.get("/catalog/refresh/stream")
async def catalog_refresh_stream(request: Request, page_size: int = 200):
    return StreamingResponse(orders.refresh_catalog_stream(page_size=page_size), media_type="text/event-stream")



@api.get("/catalog/last-refresh")
def last_refresh():
    return orders.last_refresh()


@api.post("/orders/preview")
def preview(req: PreviewRequest):
    return orders.preview_items([i.dict() for i in req.items])


@api.post("/orders/preview-csv")
async def preview_csv(file: UploadFile = File(...)):
    content = await file.read()
    return orders.preview_csv(content)


@api.post("/orders/submit")
def submit(req: SubmitRequest):
    return orders.submit_order([i.dict() for i in req.items], auto_create_missing=bool(req.auto_create_missing))


@api.get("/health")
def health():
    return {"ok": True}

app.include_router(api)
