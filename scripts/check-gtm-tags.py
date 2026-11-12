#!/usr/bin/env python3
"""Check whether the GTM container actually publishes the Google Ads tags.

Read-only. The container's compiled config is served at
`https://www.googletagmanager.com/gtm.js?id=<container>` — it contains every
published tag and trigger as plain text, so the presence of the conversion id,
the conversion label and the trigger event name can be checked from the shell
without opening a browser.

That matters here because the OAuth client this project uses has no
`tagmanager.manage` scope (the GTM API answers HTTP 403
`insufficientPermissions`), so the tags can only be created by hand in the GTM
UI — and "I clicked publish" is not the same as "the container serves it".

Usage:
    python3 scripts/check-gtm-tags.py
    python3 scripts/check-gtm-tags.py --container GTM-KBFWRCMC
    python3 scripts/check-gtm-tags.py --json
    python3 scripts/check-gtm-tags.py --site https://www.kisahtumbuh.org

Exit codes:
    0  every required marker is present in the container
    1  a required marker is missing (tags not published / wrong label)
    2  the container could not be fetched

Note on false positives: the container file also contains GTM's own runtime
code, which has the strings "CustomEvent", "GoogleTag" and "gclid" in it.
Those are function names of the built-in runtime, not tags — so they are never
used as markers here. Only the conversion id, the conversion label and the
custom event name are meaningful.
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request

GTM_JS = "https://www.googletagmanager.com/gtm.js"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"

DEFAULT_CONTAINER = "GTM-KBFWRCMC"

# Required: the two tags the ad account needs before WA Click can be counted.
# The conversion id appears in both the Conversion Linker and the Google Ads
# Conversion Tracking tag, so 2+ hits is the healthy state.
REQUIRED = (
    ("conversion id", "AW-17023304515"),
    ("WA Click label", "BypDCOiCi7YdEMOGrLU_"),
    ("trigger event", "whatsapp_clicked"),
)
# Optional: the Request quote tag (3c in the setup spec).
OPTIONAL = (("Request quote label", "nfgeCO6m4PsbEMOGrLU_"),)


def fetch(url: str, timeout: int = 45) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    try:
        return urllib.request.urlopen(req, timeout=timeout).read()
    except urllib.error.HTTPError as e:
        raise SystemExit(f"HTTP {e.code} for {url}")
    except urllib.error.URLError as e:
        raise SystemExit(f"network error for {url}: {e.reason}")


def container_text(container: str) -> str:
    # `l=dataLayer` mirrors what the page snippet requests; the response is
    # content-stable, so no cache-busting parameter is needed.
    raw = fetch(f"{GTM_JS}?id={container}&l=dataLayer").decode("utf-8", "replace")
    if "googletagmanager.com/gtm.js" not in raw and len(raw) < 1000:
        raise SystemExit(f"container {container} returned an unexpected payload")
    return raw


def check_site(site: str, container: str) -> list:
    """The site must already carry the snippet and the dataLayer push."""
    out = []
    html = fetch(site.rstrip("/") + "/").decode("utf-8", "replace")
    out.append(("GTM snippet in index.html", container in html))
    out.append(("no double gtag('config')", "gtag('config'" not in html))
    m = re.search(r"/assets/index-[A-Za-z0-9_\-]+\.js", html)
    if not m:
        out.append(("active bundle found", False))
        return out
    bundle = fetch(site.rstrip("/") + m.group(0)).decode("utf-8", "replace")
    out.append(("dataLayer.push in bundle", "dataLayer.push" in bundle))
    out.append(("whatsapp_clicked in bundle", "whatsapp_clicked" in bundle))
    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--container", default=DEFAULT_CONTAINER)
    p.add_argument("--site", help="also check the live site for snippet + dataLayer")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    args = p.parse_args()

    try:
        text = container_text(args.container)
    except SystemExit as e:
        print(f"❌ {e}", file=sys.stderr)
        return 2

    hits = {name: text.count(needle) for name, needle in REQUIRED + OPTIONAL}
    missing = [name for name, needle in REQUIRED if hits[name] == 0]
    rc = 1 if missing else 0

    if args.json:
        print(
            json.dumps(
                {
                    "container": args.container,
                    "bytes": len(text),
                    "hits": hits,
                    "missing": missing,
                    "published": not missing,
                },
                indent=2,
            )
        )
    else:
        print("=" * 62)
        print(f" GTM container {args.container} — {len(text):,} bytes")
        print("=" * 62)
        for name, _ in REQUIRED:
            n = hits[name]
            mark = "✅" if n else "❌"
            extra = f"  ({n} hit{'s' if n != 1 else ''})" if n else ""
            print(f"   {mark} {name:<20}{extra}")
        print("   ── optional ──")
        for name, _ in OPTIONAL:
            n = hits[name]
            mark = "✅" if n else "· "
            print(f"   {mark} {name:<20}{f'({n} hits)' if n else '(not published)'}")

        if missing:
            print(f"\n❌ Missing: {', '.join(missing)}")
            print("   The tags are not published in this container (yet).")
            print("   → create them in the GTM UI, then Submit → Publish,")
            print("     then re-run this check.")
        else:
            print("\n✅ Container publishes every required marker.")
            print("   Next: verify the tag actually fires — GTM → Preview →")
            print("   open the site → click a WhatsApp button → both tags must")
            print("   appear under Tags Fired.")

    if args.site:
        checks = check_site(args.site, args.container)
        if not args.json:
            print(f"\n=== SITE {args.site} ===")
        for name, ok in checks:
            if args.json:
                print(json.dumps({"site_check": name, "ok": ok}))
            else:
                print(f"   {'✅' if ok else '❌'} {name}")
            if not ok:
                rc = 1

    return rc


if __name__ == "__main__":
    raise SystemExit(main())
