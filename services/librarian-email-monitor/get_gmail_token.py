"""One-time interactive OAuth consent → prints a GMAIL_LIBRARIAN_OAUTH bundle.

Run this once, on a machine with a browser, signed into the ingress mailbox
(mesh-ingress@518computing.com). It performs the OAuth "installed app" flow for
the single scope the email-monitor needs (gmail.modify: read + label +
mark-read) and prints a JSON bundle to paste — value only — into
~/.agent-credentials.env as GMAIL_LIBRARIAN_OAUTH. The refresh token in the
bundle is long-lived for a Workspace *Internal* OAuth app (no 7-day expiry).

The printed bundle is a CREDENTIAL: it is not committed, not logged elsewhere,
and only you see this terminal. Nothing here writes to the bus.

Usage (from the repo venv): pass the client-secret JSON downloaded from the
Google Cloud Console (Clients -> Download JSON):
    ./.venv/bin/python services/librarian-email-monitor/get_gmail_token.py \
        --client-secrets ~/Desktop/client_secret_XXX.apps.googleusercontent.com.json

Depends on google-auth-oauthlib (install into the local venv):
    uv pip install google-auth-oauthlib
"""

import argparse
import json
import sys

SCOPES = ["https://www.googleapis.com/auth/gmail.modify"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--client-secrets", required=True,
        help="path to the OAuth client JSON downloaded from the Cloud Console",
    )
    args = ap.parse_args()

    try:
        from google_auth_oauthlib.flow import InstalledAppFlow
    except ImportError:
        print(
            "missing dep: run  uv pip install google-auth-oauthlib",
            file=sys.stderr,
        )
        return 1

    with open(args.client_secrets, encoding="utf-8") as fh:
        client_config = json.load(fh)
    # Google wraps the client under "installed" (Desktop app) or "web".
    node = client_config.get("installed") or client_config.get("web") or {}
    client_id = node.get("client_id", "")
    client_secret = node.get("client_secret", "")

    flow = InstalledAppFlow.from_client_config(client_config, SCOPES)
    # Opens a browser; you approve as the ingress mailbox. access_type=offline +
    # prompt=consent guarantees a refresh_token comes back.
    creds = flow.run_local_server(
        port=0, access_type="offline", prompt="consent"
    )

    bundle = {
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": creds.refresh_token,
        "token_uri": "https://oauth2.googleapis.com/token",
    }
    print("\n--- paste this as the GMAIL_LIBRARIAN_OAUTH value (single line) ---")
    print(json.dumps(bundle, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
