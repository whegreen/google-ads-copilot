#!/usr/bin/env python3
"""Check which OAuth scopes a Google OAuth client advertises.

No browser, no token, no login: the authorization endpoint rejects a scope the
client does not advertise with `invalid_scope`, and it does that before it
asks anyone to sign in. So a plain request is enough to test the client's
scope list.

That turns the slow "add the scope, re-run the login, read the error" loop
into a one second check — which matters when the scope list lives in the Cloud
console and the login needs a human.

Usage:
    python3 scripts/check-gtm-scope.py
    python3 scripts/check-gtm-scope.py --scope https://www.googleapis.com/auth/tagmanager.manage
    python3 scripts/check-gtm-scope.py --all

Exit codes:
    0  every scope checked is advertised by the client
    1  at least one scope is rejected
"""
import argparse
import json
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

AUTH = "https://accounts.google.com/o/oauth2/auth"
REDIRECT = "http://localhost:8899"

SCOPES = {
    "adwords": "https://www.googleapis.com/auth/adwords",
    "cloud-platform": "https://www.googleapis.com/auth/cloud-platform",
    "tagmanager (read)": "https://www.googleapis.com/auth/tagmanager",
    "tagmanager.manage.accounts": "https://www.googleapis.com/auth/tagmanager.manage.accounts",
    "tagmanager.manage.users": "https://www.googleapis.com/auth/tagmanager.manage.users",
    "tagmanager.manage (umbrella)": "https://www.googleapis.com/auth/tagmanager.manage",
}
REQUIRED = "https://www.googleapis.com/auth/tagmanager.manage.accounts"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def client_id() -> str:
    creds = json.loads(
        (Path(__file__).resolve().parent.parent / "data" / "google-ads-oauth-client.json").read_text()
    )["installed"]
    return creds["client_id"]


def probe(scope: str, cid: str):
    """Return (accepted, detail)."""
    url = AUTH + "?" + urllib.parse.urlencode(
        {
            "client_id": cid,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "scope": scope,
            "access_type": "offline",
            "prompt": "consent",
        }
    )
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(urllib.request.Request(url), timeout=30) as resp:
            location = resp.headers.get("Location", "")
            status = resp.status
    except urllib.error.HTTPError as e:
        location = e.headers.get("Location", "") if e.headers else ""
        status = e.code
    if "oauth/error" in location:
        return False, decode_error(location)
    if location:
        return True, "accepted (redirects to sign-in)"
    return True, f"accepted (HTTP {status})"


def decode_error(location: str) -> str:
    import base64

    m = urllib.parse.parse_qs(urllib.parse.urlparse(location).query).get("authError", [""])[0]
    s = urllib.parse.unquote(m)
    s += "=" * (-len(s) % 4)
    try:
        return base64.urlsafe_b64decode(s).decode("utf-8", "replace").replace("\n", " ").strip()
    except Exception:
        return "rejected"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--scope", action="append", help="scope to check (repeatable)")
    p.add_argument("--all", action="store_true", help="check the known scope list")
    args = p.parse_args()

    cid = client_id()
    print("=" * 74)
    print(f" OAuth client {cid}")
    print("=" * 74)

    if args.scope:
        items = [(s, s) for s in args.scope]
    elif args.all:
        items = list(SCOPES.items())
    else:
        items = [("tagmanager.manage.accounts", REQUIRED)]

    failed = False
    for label, scope in items:
        ok, detail = probe(scope, cid)
        print(f"   {'✅' if ok else '❌'} {label:<28} {detail}")
        if not ok:
            failed = True

    print()
    if failed:
        print(f"❌ {REQUIRED} is NOT advertised by this client.")
        print("   Google Cloud Console → Google Auth Platform → Data Access →")
        print("   'Add or remove scopes' → API 'Tag Manager API' → add")
        print("   'View and manage your Google Tag Manager accounts'")
        print("   (scope value ends in /auth/tagmanager.manage.accounts) → press")
        print("   UPDATE. Then re-run this script; it must turn green before")
        print("   logging in.")
        return 1
    print("✅ every scope checked is advertised by this client")
    print("   Next: python3 scripts/oauth-login.py  (a fresh consent is needed —")
    print("   an existing refresh token never gains a scope on its own)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
