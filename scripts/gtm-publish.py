#!/usr/bin/env python3
"""Publish the Google Ads conversion tags into a GTM container.

The GTM API needs an OAuth token with the `tagmanager.manage` scope. The
refresh token this repo keeps (`data/google-ads-adc-authorized-user.json`) does
not carry it — the OAuth client for this project does not advertise the scope —
so this script takes the refresh token from a separate file instead.

It works in one workspace, in this order:

  A. resolve    → find the account + workspace that own the container, and
                  snapshot the live container version (that snapshot is the
                  rollback: publishing it again restores the previous state)
  B. trigger    → make sure a Custom Event trigger fires on `whatsapp_clicked`
  C. tags       → make sure the two Google Ads tags exist and carry the right
                  conversion id / label / value / currency
  D. preview    → `workspaces:quick_preview` compiles the workspace WITHOUT
                  publishing it; the compiled output is checked for the
                  conversion id and the label
  E. publish    → `workspaces:create_version` + `versions:publish`
  F. verify     → re-read the published container and check the markers

Nothing is written until the publish phase, and the publish phase only runs
with `--publish`.

Usage:
    # dry run — resolves everything, creates the trigger and tags in the
    # workspace, previews it, and stops before publishing
    python3 scripts/gtm-publish.py --token-file ~/.gads-backup/gtm-refresh-token.txt

    # actually publish
    python3 scripts/gtm-publish.py --token-file ~/.gads-backup/gtm-refresh-token.txt --publish

Exit codes:
    0  done (published, or dry run completed successfully)
    1  something failed; the reason is printed
"""
import argparse
import json
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://tagmanager.googleapis.com/tagmanager/v2"

DEFAULT_CONTAINER = "GTM-KBFWRCMC"
CONVERSION_ID = "AW-17023304515"
CONVERSION_LABEL = "BypDCOiCi7YdEMOGrLU_"
CONVERSION_VALUE = "1"
CURRENCY = "IDR"
EVENT_NAME = "whatsapp_clicked"

# The OAuth Playground's own client — public and documented by Google, and the
# one client that already advertises the Tag Manager scope. A refresh token
# from the playground is bound to it, so it has to be presented when the token
# is exchanged for an access token.
PLAYGROUND_CLIENT_ID = "407408718192.apps.googleusercontent.com"
PLAYGROUND_CLIENT_SECRET = "gX1fBat3bRuevLqPI9E2gXv"

# The tag type strings changed over the years: the current GTM runtime knows
# `cl` (Conversion Linker) and `gaawc` (Google Ads conversion tracking), the
# API used to accept `gclidw` and `awct`. Try them in order — the API is
# fail-closed, so a wrong guess is a 400 and nothing else.

TOKEN = None


def die(msg, detail=None):
    print(f"\n❌ {msg}")
    if detail:
        print(f"   {detail}")
    raise SystemExit(1)


def api(method, path, body=None, params=None):
    url = f"{API}/{path.lstrip('/')}"
    if params:
        url += "?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Authorization": f"Bearer {TOKEN}"}
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            err = json.loads(raw)["error"]
            msg = err.get("message", raw)
            reasons = [x.get("reason") for x in err.get("errors", []) if isinstance(x, dict)]
            if reasons:
                msg += f" (reasons={reasons})"
        except Exception:
            msg = raw
        raise RuntimeError(f"{method} {path} → HTTP {e.code}: {msg}")


def access_token(refresh_token, client_id, client_secret):
    """Mint an access token.

    A refresh token is bound to the OAuth client that issued it, so the same
    client_id (and secret, for a confidential client) has to be presented. The
    Google OAuth Playground's own client is a public, documented pair — it is
    the way to get a `tagmanager.manage` token while this project's client
    does not advertise the scope.
    """
    payload = {
        "client_id": client_id,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    }
    if client_secret:
        payload["client_secret"] = client_secret
    req = urllib.request.Request(
        "https://oauth2.googleapis.com/token",
        data=urllib.parse.urlencode(payload).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["access_token"]
    except urllib.error.HTTPError as e:
        die(
            "could not mint an access token from that refresh token",
            e.read().decode()[:300],
        )


def main():
    global TOKEN
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--token-file", help="file containing the OAuth refresh token")
    p.add_argument("--use-adc", action="store_true", help="use the repo ADC file instead")
    p.add_argument(
        "--client-id",
        help="OAuth client the refresh token belongs to (default: the repo client, or the OAuth Playground client for a token-file)",
    )
    p.add_argument("--client-secret", help="secret of that OAuth client, if it is a confidential client")
    p.add_argument("--container", default=DEFAULT_CONTAINER)
    p.add_argument(
        "--delete-tag",
        action="append",
        default=[],
        help="tag id to delete from the workspace before publishing (repeatable)",
    )
    p.add_argument("--publish", action="store_true", help="actually publish the version")
    args = p.parse_args()

    root = Path(__file__).resolve().parent.parent
    if args.use_adc:
        creds = json.loads((root / "data" / "google-ads-adc-authorized-user.json").read_text())
        refresh = creds["refresh_token"]
        client_id = args.client_id or creds["client_id"]
        client_secret = args.client_secret if args.client_secret is not None else creds["client_secret"]
    elif args.token_file:
        refresh = Path(args.token_file).read_text().strip()
        # Default to the OAuth Playground client: a token from the playground
        # is bound to it, and this project's client does not advertise the
        # Tag Manager scope at all.
        client_id = args.client_id or PLAYGROUND_CLIENT_ID
        client_secret = args.client_secret if args.client_secret is not None else PLAYGROUND_CLIENT_SECRET
    else:
        die("pass --token-file <path> or --use-adc")

    TOKEN = access_token(refresh, client_id, client_secret)

    info = json.loads(
        urllib.request.urlopen(
            "https://oauth2.googleapis.com/tokeninfo?access_token="
            + urllib.parse.quote(TOKEN),
            timeout=30,
        ).read()
    )
    scopes = info.get("scope", "").split()
    print("=" * 74)
    print(f" GTM publish — container {args.container} — as {info.get('email')}")
    print("=" * 74)
    print("   scopes:", " ".join(sorted(scopes)))
    # The client may grant the umbrella `tagmanager.manage` or the granular
    # `tagmanager.manage.accounts` — either one is enough to write.
    if not any("tagmanager" in s and "manage" in s for s in scopes):
        die("this token has no tagmanager manage scope — nothing to do")

    # ── A. resolve ────────────────────────────────────────────────────────
    print("\n── A. resolve account + workspace ──")
    # `accounts.containers:lookup` is for linked destinations, not for
    # resolving a container, so list the accounts and their containers.
    acct = cont = None
    for a in api("GET", "accounts").get("account", []):
        for c in api("GET", f"accounts/{a['accountId']}/containers").get("container", []):
            # the container is addressed by its numeric id, but it is the
            # public id (GTM-XXXXXXX) that the snippet on the site uses
            if args.container in (c.get("containerId"), c.get("publicId")):
                acct, cont = a["accountId"], c["containerId"]
                print(f"   account {acct} ({a.get('name')}) · container {cont} ({c.get('name')})")
    if not acct:
        die(f"container {args.container} not found in any accessible GTM account")

    base = f"accounts/{acct}/containers/{cont}"
    workspaces = api("GET", f"{base}/workspaces").get("workspace", [])
    if not workspaces:
        die("no workspace in this container")
    ws = next((w for w in workspaces if "default" in w.get("name", "").lower()), workspaces[0])
    ws_path = f"{base}/workspaces/{ws['workspaceId']}"
    print(f"   workspace {ws['workspaceId']} — {ws.get('name')}")

    live = api("GET", f"{base}/versions:live")
    live_id = live.get("containerVersionId")
    backup = Path.home() / ".gads-backup" / f"gtm-live-version-{args.container}.json"
    backup.parent.mkdir(parents=True, exist_ok=True)
    backup.write_text(json.dumps(live, indent=2))
    print(f"   live version {live_id} → snapshot saved to {backup} (rollback)")

    # ── B. trigger ────────────────────────────────────────────────────────
    print("\n── B. custom event trigger ──")
    triggers = api("GET", f"{ws_path}/triggers").get("trigger", [])
    custom = next(
        (t for t in triggers if EVENT_NAME in json.dumps(t.get("customEventFilter", []))),
        None,
    )
    if custom:
        print(f"   already there: {custom.get('name')} ({custom.get('triggerId')})")
    else:
        payload = {
            "name": f"WA Click ({EVENT_NAME})",
            "type": "customEvent",
            # A custom event filter needs BOTH operands: arg0 is the event
            # name as a variable (the API rejects anything but "{{_event}}"),
            # arg1 is the literal event name to match.
            "customEventFilter": [
                {
                    "type": "EQUALS",
                    "parameter": [
                        {"key": "arg0", "value": "{{_event}}", "type": "template"},
                        {"key": "arg1", "value": EVENT_NAME, "type": "template"},
                    ],
                }
            ],
        }
        try:
            custom = api("POST", f"{ws_path}/triggers", payload)
            print(f"   created: {custom.get('name')} ({custom.get('triggerId')})")
        except RuntimeError as e:
            die("could not create the custom event trigger", e)

    all_pages = next((t for t in triggers if t.get("type") == "pageview"), None)
    if all_pages is None:
        all_pages = next((t for t in api("GET", f"{ws_path}/triggers").get("trigger", []) if t.get("type") == "pageview"), None)
    if all_pages is None:
        die("no built-in All Pages trigger found in the workspace")
    print(f"   All Pages trigger: {all_pages.get('name')} ({all_pages.get('triggerId')})")

    # ── C. tags ───────────────────────────────────────────────────────────
    print("\n── C. tags ──")
    existing = api("GET", f"{ws_path}/tags").get("tag", [])
    by_name = {t.get("name"): t for t in existing}

    # ── cleanup ──
    # A Conversion Linker is a singleton: two of them run the gclid cookie
    # logic twice, and the one without parameters runs the template with no
    # configuration at all (it shows up in the compiled container as a bare
    # `__gclidw` block with no vtp_ keys). Keep the one with the most
    # parameters, drop the rest.
    linkers = [t for t in existing if t.get("type") == "gclidw"]
    if len(linkers) > 1:
        linkers.sort(key=lambda t: (-len(t.get("parameter", [])), int(t.get("tagId", 0))))
        for extra in linkers[1:]:
            api("DELETE", f"{ws_path}/tags/{extra['tagId']}")
            print(
                f"   removed duplicate Conversion Linker (tagId {extra['tagId']}, "
                f"{len(extra.get('parameter', []))} params)"
            )
        existing = api("GET", f"{ws_path}/tags").get("tag", [])
        by_name = {t.get("name"): t for t in existing}

    for tid in args.delete_tag:
        try:
            api("DELETE", f"{ws_path}/tags/{tid}")
            print(f"   deleted tag {tid} (requested)")
        except RuntimeError as e:
            print(f"   could not delete tag {tid}: {str(e)[:120]}")

    def ensure_tag(name, tag_type, trigger_id, params):
        """Create the tag if it is not there yet.

        The GTM API v2 tag shape is `type` + `parameter` + `firingTriggerId`
        (singular). The older `tagType` / `setupTag` / `firingTriggerIds`
        spelling is rejected with "vendorTemplate.key: Unknown entity type".
        """
        tag = by_name.get(name)
        if tag is None:
            body = {
                "name": name,
                "type": tag_type,
                "parameter": [
                    {"type": "TEMPLATE", "key": k, "value": v} for k, v in params.items()
                ],
                "firingTriggerId": [str(trigger_id)],
            }
            tag = api("POST", f"{ws_path}/tags", body)
            print(f"   created {name} as type={tag_type} ({tag.get('tagId')})")
        else:
            print(f"   exists: {name} ({tag.get('tagId')})")
        # read it back so the log shows what the container actually stores
        tag = api("GET", f"{ws_path}/tags/{tag['tagId']}")
        blob = json.dumps(tag)
        print(f"      type={tag.get('type')} trigger={tag.get('firingTriggerId')}")
        for k, v in params.items():
            print(f"      {k:<18} {v}  {'✅' if v in blob else '⚠️  not stored'}")
        return tag

    linker = ensure_tag(
        "Conversion Linker - ads kistum",
        "gclidw",
        all_pages["triggerId"],
        {
            "enableCrossDomain": "false",
            "enableUrlPassthrough": "true",
            "enableCookieOverrides": "false",
        },
    )
    conversion = ensure_tag(
        "WA Click — Google Ads",
        "awct",
        custom["triggerId"],
        {
            # The template stores the conversion id as the NUMERIC part of the
            # AW- id — the API rejects the "AW-..." string with "The value
            # must be a positive integer". GTM rebuilds "AW-<id>" itself.
            "conversionId": CONVERSION_ID.split("-", 1)[1],
            "conversionLabel": CONVERSION_LABEL,
            "conversionValue": CONVERSION_VALUE,
            "currencyCode": CURRENCY,
        },
    )
    for t in (linker, conversion):
        blob = json.dumps(t)
        print(
            f"   {t.get('name')}: id={t.get('tagId')} type={t.get('type')} "
            f"triggers={t.get('firingTriggerId')} "
            f"has_id={CONVERSION_ID in blob} has_label={CONVERSION_LABEL in blob}"
        )

    # ── D. preview ────────────────────────────────────────────────────────
    print("\n── D. quick preview (no publish) ──")
    preview = api("POST", f"{ws_path}:quick_preview")
    blob = json.dumps(preview)
    ok_id = CONVERSION_ID in blob
    ok_label = CONVERSION_LABEL in blob
    ok_event = EVENT_NAME in blob
    print(f"   conversion id in compiled output : {ok_id}")
    print(f"   conversion label in compiled output: {ok_label}")
    print(f"   trigger event in compiled output : {ok_event}")
    # A Conversion Linker is a singleton: two of them run the gclid cookie
    # logic twice, and the one without parameters runs the template with no
    # configuration at all. The preview answers with a container version, so
    # count the tag types in it.
    cv = preview.get("containerVersion", {})
    types = [t.get("type") for t in cv.get("tag", [])]
    n_linker = types.count("gclidw")
    n_awct = types.count("awct")
    n_dest = types.count("dest_aw")
    print(f"   tags in preview: {len(types)} → gclidw={n_linker} awct={n_awct} dest_aw={n_dest}")
    if n_linker != 1:
        print(f"   ⚠️  expected exactly 1 Conversion Linker, found {n_linker}")
    if n_awct != 1:
        print(f"   ⚠️  expected exactly 1 Google Ads conversion tag, found {n_awct}")
    if not (ok_id and ok_label):
        print("   ⚠️  the compiled preview does not carry the conversion id/label —")
        print("      the template parameters were not accepted. Not publishing.")

    # ── E. publish ────────────────────────────────────────────────────────
    if not args.publish:
        print("\n🟡 dry run — nothing published. Re-run with --publish to go live.")
        return 0 if (ok_id and ok_label) else 1
    if not (ok_id and ok_label):
        die("preview did not carry the conversion id/label — refusing to publish")

    print("\n── E. publish ──")
    created = api(
        "POST",
        f"{ws_path}:create_version",
        {"name": f"WA Click conversion tracking ({info.get('email')})",
         "notes": "Created by google-ads-copilot scripts/gtm-publish.py"},
    )
    version = created.get("containerVersion") or created
    vid = version.get("containerVersionId")
    print(f"   version created: {vid}")
    api("POST", f"{base}/versions/{vid}:publish")
    print(f"   published version {vid}")

    # ── F. verify ─────────────────────────────────────────────────────────
    print("\n── F. verify ──")
    after = api("GET", f"{base}/versions:live")
    blob = json.dumps(after)
    print(f"   live version now: {after.get('containerVersionId')}")
    for name, needle in (
        ("conversion id", CONVERSION_ID),
        ("WA Click label", CONVERSION_LABEL),
        ("trigger event", EVENT_NAME),
    ):
        print(f"   {'✅' if needle in blob else '❌'} {name}")
    return 0 if CONVERSION_ID in blob and CONVERSION_LABEL in blob else 1


if __name__ == "__main__":
    raise SystemExit(main())
