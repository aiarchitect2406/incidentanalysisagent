"""REST-based Skill Publisher.
Bypasses the broken vertexai.Client.skills attribute in the SDK.
"""
import base64
import io
import json
import os
import pathlib
import sys
import zipfile
import google.auth
import google.auth.transport.requests
import requests

SKILL_DIR = pathlib.Path(__file__).resolve().parents[3] / "enterprise_support_agent" / "skills" / "incident-escalator"
SKILL_ID = os.environ.get("SKILL_REGISTRY_INCIDENT_SKILL", "incident-escalator")
DISPLAY_NAME = SKILL_ID
DESCRIPTION = "Enterprise support incident triage with parallel investigation, P0 escalation, and self-healing JVM heap remediation."

def build_zip_bytes() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as zip_file:
        # Add SKILL.md to the root of the zip archive
        skill_file = SKILL_DIR / "SKILL.md"
        if not skill_file.is_file():
            raise FileNotFoundError(f"SKILL.md not found at {skill_file}")
        zip_file.write(skill_file, "SKILL.md")
    return buffer.getvalue()

def publish():
    project = os.environ.get("GOOGLE_CLOUD_PROJECT")
    if not project:
        raise ValueError("GOOGLE_CLOUD_PROJECT env var is required")
    location = "us-central1"
    
    # Get Credentials
    credentials, project_id_auth = google.auth.default()
    auth_request = google.auth.transport.requests.Request()
    credentials.refresh(auth_request)
    token = credentials.token

    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json"
    }

    base_url = f"https://us-central1-aiplatform.googleapis.com/v1beta1/projects/{project}/locations/{location}/skills"
    full_name = f"{base_url}/{SKILL_ID}"

    print(f"[REST Publish] Project: {project}  Location: {location}")
    print(f"[REST Publish] Skill ID: {SKILL_ID}")

    # 1. Delete previous skill
    print(f"[REST Publish] Deleting previous skill: {full_name}...")
    del_resp = requests.delete(full_name, headers=headers)
    if del_resp.status_code in [200, 204]:
        print("[REST Publish] Deleted previous skill successfully.")
    else:
        print(f"[REST Publish] Delete response status: {del_resp.status_code}. Content: {del_resp.text}")

    # 2. Build ZIP and base64
    zip_bytes = build_zip_bytes()
    zip_b64 = base64.b64encode(zip_bytes).decode("utf-8")

    # 3. Create new skill
    payload = {
        "displayName": DISPLAY_NAME,
        "description": DESCRIPTION,
        "zippedFilesystem": zip_b64
    }

    create_url = f"{base_url}?skillId={SKILL_ID}"
    print(f"[REST Publish] Creating skill: {create_url}...")
    create_resp = requests.post(create_url, headers=headers, json=payload)
    if create_resp.status_code in [200, 201]:
        print(f"[REST Publish] Created skill successfully! Response: {create_resp.json()}")
    else:
        print(f"[REST Publish] Create failed: {create_resp.status_code} - {create_resp.text}")
        sys.exit(1)

if __name__ == "__main__":
    publish()
