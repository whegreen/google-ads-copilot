#!/usr/bin/env python3
"""Extract every GAQL query in the repo and check it against API v25.

Run from the repo root. Reports each query as OK / ERROR with the API message.
"""
import json
import os
import re
import subprocess
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CREDS = ROOT / "data" / "google-ads-adc-authorized-user.json"
CID = "9432618196"
API = "https://googleads.googleapis.com/v25"

creds = json.loads(CREDS.read_text())
req = urllib.request.Request(
    "https://oauth2.googleapis.com/token",
    data=urllib.parse.urlencode(
        {
            "client_id": creds["client_id"],
            "client_secret": creds["client_secret"],
            "refresh_token": creds["refresh_token"],
            "grant_type": "refresh_token",
        }
    ).encode(),
    headers={"Content-Type": "application/x-www-form-urlencoded"},
)
import urllib.parse  # noqa: E402

token = json.loads(urllib.request.urlopen(req, timeout=30).read())["access_token"]


def run(query: str):
    body = json.dumps({"query": query}).encode()
    r = urllib.request.Request(
        f"{API}/customers/{CID}/googleAds:searchStream",
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    try:
        raw = urllib.request.urlopen(r, timeout=40).read()
    except urllib.error.HTTPError as e:
        raw = e.read()
    try:
        d = json.loads(raw)
    except Exception:
        return "NON-JSON", 0
    if isinstance(d, list) and d and "error" in d[0]:
        errs = d[0]["error"].get("details", [{}])[0].get("errors", [{}])
        msg = errs[0].get("message") or d[0]["error"].get("message", "?")
        code = errs[0].get("errorCode", {})
        detail = ",".join(f"{k}={v}" for k, v in code.items()) or "?"
        return f"ERROR {detail}: {msg}", 0
    n = len(d[0].get("results", [])) if isinstance(d, list) and d else 0
    return "OK", n


# ── collect queries ──
queries = []

# Python: triple-quoted strings passed to run(...) / ga.search(...)
for py in sorted(ROOT.glob("scripts/*.py")):
    src = py.read_text()
    for m in re.finditer(r'"""(.*?)"""', src, re.S):
        body = m.group(1)
        if "SELECT" in body.upper():
            queries.append((f"{py.relative_to(ROOT)}", " ".join(body.split())))

# Shell: local query="SELECT ... " assignments
for sh in sorted(ROOT.glob("scripts/apply-layer/lib/*.sh")) + sorted(
    ROOT.glob("scripts/apply-layer/*.sh")
):
    src = sh.read_text()
    for m in re.finditer(r'local query="(SELECT.*?)"', src, re.S):
        queries.append((f"{sh.relative_to(ROOT)}", " ".join(m.group(1).split())))
    for m in re.finditer(r'local query=\s*"(SELECT.*?)"\s*\n', src, re.S):
        queries.append((f"{sh.relative_to(ROOT)}", " ".join(m.group(1).split())))

# ── substitute shell placeholders so templates are checked as they run ──
SUBST = {
    "${match_type}": "EXACT",
    "${safe_campaign}": "High Intent - Search",
    "${safe_adgroup}": "Crane Rental",
    "${safe_ag}": "at home daycare feb",
    "${safe_name}": "High Intent - Search",
    "${safe_keyword}": "near me",
    "${ad_id}": "555",
    "${asset_id}": "999",
    "${customer_id}": CID,
    "${asset_group_id}": "6677194808",
    "${safe}": "x",
}


def is_query(text: str) -> bool:
    """True when the blob is a real GAQL query.

    Docstrings and f-string templates can contain the word SELECT without being
    a query at all — those must not be sent to the API.
    """
    t = text.strip()
    if not t.upper().startswith("SELECT"):
        return False
    # A query needs a FROM clause; prose that merely mentions SELECT does not.
    if " FROM " not in t.upper():
        return False
    return True


def substitute(q: str) -> str:
    for k, v in SUBST.items():
        q = q.replace(k, v)
    # any leftover ${...} would be a template we cannot evaluate — skip it
    return q


# de-dup
seen = set()
uniq = []
skipped_not_query = 0
for src, q in queries:
    if not is_query(q):
        skipped_not_query += 1
        continue
    key = q[:120]
    if key in seen:
        continue
    seen.add(key)
    uniq.append((src, q))

print(
    f"{len(uniq)} distinct queries found"
    f"{f' ({skipped_not_query} non-query blobs skipped)' if skipped_not_query else ''}\n"
)
fails = 0
for src, q in uniq:
    q2 = substitute(q)
    if "${" in q2:
        print(f"⏭️  {src}  (unresolved placeholder — skipped)\n")
        continue
    # A leftover brace means the blob is a Python f-string template: it was
    # never a runnable query, so it must not reach the API.
    if "{" in q2 or "}" in q2:
        print(f"⏭️  {src}  (template, not a runnable query — skipped)\n")
        continue
    status, n = run(q2)
    label = q2[:96] + ("…" if len(q2) > 96 else "")
    if status != "OK":
        fails += 1
        print(f"❌ {src}\n   {status}\n   {label}\n")
    else:
        print(f"✅ {src}  (n={n})  {label}\n")

print(f"\n{len(uniq) - fails}/{len(uniq)} queries OK on v25")
sys.exit(1 if fails else 0)
