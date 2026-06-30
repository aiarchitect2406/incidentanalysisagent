"""Run the incident-escalator eval set against the deployed Agent Runtime.

Results land in the GEAP Observability → Evaluation sub-tab in the Agent
Registry. Use this both to (a) seed the Evaluation widget for the demo
and (b) detect drift before the live presentation.
"""
from __future__ import annotations

import pathlib
import sys

import vertexai
from google.adk.evaluation.agent_evaluator import AgentEvaluator

from enterprise_support_agent import config
from enterprise_support_agent.logging_setup import init_logging

logger = init_logging()


EVAL_SET = pathlib.Path(__file__).resolve().parent.parent / "enterprise_support_agent" / "evals" / "incident_escalation.evalset.json"


def run() -> None:
    project = config.project_id()
    location = config.location()
    vertexai.init(project=project, location=location, staging_bucket=config.staging_bucket())

    logger.info(
        "agent_eval_starting",
        extra={"json_fields": {"eval_set": str(EVAL_SET), "project": project, "location": location}},
    )

    AgentEvaluator.evaluate(
        agent_module="enterprise_support_agent",
        eval_dataset_file_path_or_dir=str(EVAL_SET),
        num_runs=1,
    )

    logger.info("agent_eval_complete")


if __name__ == "__main__":
    try:
        run()
    except Exception as exc:
        logger.exception("agent_eval_failed")
        print(f"EVAL FAILED: {exc}", file=sys.stderr)
        sys.exit(1)
