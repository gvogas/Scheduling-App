"""Create non-production Firebase placeholders for unsigned simulator checks."""

import json
import os
from pathlib import Path
import plistlib


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise SystemExit("This configuration helper runs only in GitHub Actions.")
    plist_path = Path("ios/GoogleService-Info.plist")
    if plist_path.exists():
        raise SystemExit("Refusing to overwrite an existing Firebase plist.")
    project = "demo-scheduling-native-ci"
    app_id = "1:000000000000:ios:0000000000000000"
    api_key = "AIzaSy" + "0" * 33
    config = {
        "IOS_API_KEY": api_key,
        "IOS_APP_ID": app_id,
        "MESSAGING_SENDER_ID": "000000000000",
        "PROJECT_ID": project,
        "STORAGE_BUCKET": project + ".appspot.com",
        "IOS_MAPS_API_KEY": "",
        "USE_FIREBASE_EMULATOR": True,
        "EMULATOR_HOST": "127.0.0.1",
    }
    output = Path("build/native-ci")
    output.mkdir(parents=True, exist_ok=True)
    (output / "firebase.json").write_text(json.dumps(config), encoding="utf-8")
    with plist_path.open("wb") as plist_file:
        plistlib.dump({
            "API_KEY": api_key,
            "GOOGLE_APP_ID": app_id,
            "GCM_SENDER_ID": "000000000000",
            "PROJECT_ID": project,
            "STORAGE_BUCKET": config["STORAGE_BUCKET"],
            "BUNDLE_ID": "net.vogas.scheduling",
            "PLIST_VERSION": "1",
            "IS_ADS_ENABLED": False,
            "IS_ANALYTICS_ENABLED": False,
            "IS_APPINVITE_ENABLED": False,
            "IS_GCM_ENABLED": False,
            "IS_SIGNIN_ENABLED": False,
        }, plist_file)


if __name__ == "__main__":
    main()
