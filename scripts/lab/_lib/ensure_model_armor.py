"""Create the Model Armor template if it doesn't already exist (idempotent).

Uses the `google-cloud-modelarmor` SDK instead of `gcloud model-armor` —
the SDK resolves Application Default Credentials the same way the rest of
this repo's Python does, which is more portable than the `gcloud
model-armor` CLI surface. In at least one observed
environment, `gcloud model-armor templates create/describe` failed with a
`PERMISSION_DENIED ... authenticated as None` error via ADC-override
credential resolution, even though the identical identity had `roles/owner`
and worked fine for every other gcloud command and every other SDK call in
this repo. Root cause not fully isolated; this script sidesteps it entirely
rather than depending on a specific gcloud CLI credential path.

Usage:
    python3 scripts/lab/_lib/ensure_model_armor.py TEMPLATE_ID PROJECT_ID LOCATION
"""
from __future__ import annotations

import sys

from google.api_core.client_options import ClientOptions
from google.api_core.exceptions import AlreadyExists, NotFound
from google.cloud import modelarmor_v1


def ensure_template(template_id: str, project_id: str, location: str) -> str:
    client = modelarmor_v1.ModelArmorClient(
        client_options=ClientOptions(api_endpoint=f"modelarmor.{location}.rep.googleapis.com")
    )
    name = f"projects/{project_id}/locations/{location}/templates/{template_id}"

    try:
        client.get_template(name=name)
        print(f"[ensure_model_armor] Already exists: {name}")
        return name
    except NotFound:
        pass

    template = modelarmor_v1.Template(
        filter_config=modelarmor_v1.FilterConfig(
            rai_settings=modelarmor_v1.RaiFilterSettings(
                rai_filters=[
                    modelarmor_v1.RaiFilterSettings.RaiFilter(
                        filter_type=modelarmor_v1.RaiFilterType.HATE_SPEECH,
                        confidence_level=modelarmor_v1.DetectionConfidenceLevel.MEDIUM_AND_ABOVE,
                    ),
                    modelarmor_v1.RaiFilterSettings.RaiFilter(
                        filter_type=modelarmor_v1.RaiFilterType.HARASSMENT,
                        confidence_level=modelarmor_v1.DetectionConfidenceLevel.MEDIUM_AND_ABOVE,
                    ),
                    modelarmor_v1.RaiFilterSettings.RaiFilter(
                        filter_type=modelarmor_v1.RaiFilterType.DANGEROUS,
                        confidence_level=modelarmor_v1.DetectionConfidenceLevel.MEDIUM_AND_ABOVE,
                    ),
                    modelarmor_v1.RaiFilterSettings.RaiFilter(
                        filter_type=modelarmor_v1.RaiFilterType.SEXUALLY_EXPLICIT,
                        confidence_level=modelarmor_v1.DetectionConfidenceLevel.MEDIUM_AND_ABOVE,
                    ),
                ]
            ),
            pi_and_jailbreak_filter_settings=modelarmor_v1.PiAndJailbreakFilterSettings(
                filter_enforcement=modelarmor_v1.PiAndJailbreakFilterSettings.PiAndJailbreakFilterEnforcement.ENABLED,
                confidence_level=modelarmor_v1.DetectionConfidenceLevel.HIGH,
            ),
            malicious_uri_filter_settings=modelarmor_v1.MaliciousUriFilterSettings(
                filter_enforcement=modelarmor_v1.MaliciousUriFilterSettings.MaliciousUriFilterEnforcement.ENABLED,
            ),
        ),
    )
    request = modelarmor_v1.CreateTemplateRequest(
        parent=f"projects/{project_id}/locations/{location}",
        template_id=template_id,
        template=template,
    )
    try:
        result = client.create_template(request=request)
        print(f"[ensure_model_armor] Created: {result.name}")
        return result.name
    except AlreadyExists:
        # Race with a concurrent lab run under the same LAB_USER_ID — fine.
        print(f"[ensure_model_armor] Already exists (race): {name}")
        return name


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print("Usage: ensure_model_armor.py TEMPLATE_ID PROJECT_ID LOCATION", file=sys.stderr)
        sys.exit(2)
    try:
        ensure_template(*sys.argv[1:4])
    except Exception as exc:
        print(f"FAILED: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(1)
