"""Schema-constrained requirement extraction for the revised (v2) input model.

Implements the extraction stage of the paper's Section 4 input model
(Table tab:req-dims): mandatory constraints (target scale, traffic-path
transparency, self-managed Kubernetes, monthly budget limit, required
routing-control capability), ranking preferences (control direction, stated
priority), and the routing-expertise profile field. The model records what
the operator stated; feasibility and ranking are derived downstream by the
rule engine.

Reuses the gateway client and model of llm.py. Not yet wired into app.py;
the v1 RequirementVector path remains the deployed API until the backend
migration completes.
"""
from dataclasses import dataclass
from typing import Optional
import json

import llm  # gateway client + model


class ClarificationNeeded(Exception):
    def __init__(self, question: str):
        self.question = question
        super().__init__(question)


@dataclass
class ExtractedFields:
    scale: Optional[int]
    transparency_required: bool
    self_managed_required: bool
    budget_limit_usd: Optional[float]
    control_capability_required: bool
    stated_priority: str        # cost_first | balanced | perf_first | unspecified
    routing_expertise: str      # beginner | intermediate | expert | unspecified

    def as_dict(self):
        return {
            "scale": self.scale,
            "transparency_required": self.transparency_required,
            "self_managed_required": self.self_managed_required,
            "budget_limit_usd": self.budget_limit_usd,
            "control_capability_required": self.control_capability_required,
            "stated_priority": self.stated_priority,
            "routing_expertise": self.routing_expertise,
        }


SYSTEM_PROMPT = (
    "You are NARO (NAtive ROuting advisor), an expert system that helps Kubernetes "
    "operators choose a pod-networking configuration in public clouds. Extract ONLY "
    "what the operator explicitly states; never infer a value from unrelated "
    "quantities (pod counts, request rates, unrelated dollar amounts). "
    "Mandatory constraints must be stated as requirements: a wish or soft preference "
    "is NOT a constraint. In particular, a monthly budget is extracted only when it "
    "is a strict/hard limit on recurring routing- or managed-service fees, and a "
    "routing-control capability is marked required only when the operator states a "
    "concrete capability (e.g., registering or withdrawing routes themselves) as "
    "mandatory rather than preferred. Fields the operator does not mention stay at "
    "their unspecified defaults. If the cluster size (worker-node count) is not "
    "stated, set clarification_needed to true and ask for it; do not guess."
)

EXTRACT_TOOL = {
    "type": "function",
    "function": {
        "name": "extract_requirements",
        "description": "Record the operator's stated requirements, preferences, and profile.",
        "parameters": {
            "type": "object",
            "properties": {
                "clarification_needed": {
                    "type": "boolean",
                    "description": "True when the worker-node count is not stated, or when a stated mandatory requirement cannot be evaluated without a missing value.",
                },
                "clarification_question": {
                    "type": "string",
                    "description": "The question to ask the operator when clarification_needed is true.",
                },
                "scale": {
                    "type": "integer",
                    "description": "Stated worker-node count (use the target/peak scale if a growth range is given). Omit if not stated.",
                },
                "transparency_required": {
                    "type": "boolean",
                    "description": "True when pod traffic must traverse the cloud network without overlay encapsulation (pod IPs directly visible / encapsulation prohibited / native routing required).",
                },
                "self_managed_required": {
                    "type": "boolean",
                    "description": "True when the cluster is or must be self-managed Kubernetes (e.g., kubeadm), so a provider-managed cluster is not an option. False when a managed service is in use or acceptable, or when unstated.",
                },
                "budget_limit_usd": {
                    "type": "number",
                    "description": "Strict monthly limit in USD on recurring routing-/managed-service fees, only when stated as a hard cap. Omit for soft wishes, general cost sensitivity, or unrelated spending figures.",
                },
                "control_capability_required": {
                    "type": "boolean",
                    "description": "True only when a concrete routing-control capability (direct control over route registration, advertisement, update, or withdrawal) is stated as mandatory.",
                },
                "stated_priority": {
                    "type": "string",
                    "enum": ["cost_first", "balanced", "perf_first", "unspecified"],
                    "description": "Stated overall priority between cost and performance; unspecified when not mentioned.",
                },
                "routing_expertise": {
                    "type": "string",
                    "enum": ["beginner", "intermediate", "expert", "unspecified"],
                    "description": "Stated BGP/routing expertise of the team; unspecified when not mentioned.",
                },
            },
            "required": [
                "clarification_needed",
                "transparency_required",
                "self_managed_required",
                "control_capability_required",
                "stated_priority",
                "routing_expertise",
            ],
        },
    },
}


def extract(text: str) -> ExtractedFields:
    client = llm._get_client()
    response = client.chat.completions.create(
        model=llm._MODEL,
        messages=[
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user",
             "content": "Extract the deployment requirements from the following operator description:\n\n" + text},
        ],
        tools=[EXTRACT_TOOL],
        tool_choice={"type": "function", "function": {"name": "extract_requirements"}},
    )
    data = json.loads(response.choices[0].message.tool_calls[0].function.arguments)
    if data.get("clarification_needed") or data.get("scale") in (None, 0):
        raise ClarificationNeeded(
            data.get("clarification_question")
            or "How many worker nodes do you plan to run?")
    return ExtractedFields(
        scale=int(data["scale"]),
        transparency_required=bool(data.get("transparency_required", False)),
        self_managed_required=bool(data.get("self_managed_required", False)),
        budget_limit_usd=(float(data["budget_limit_usd"])
                          if data.get("budget_limit_usd") is not None else None),
        control_capability_required=bool(data.get("control_capability_required", False)),
        stated_priority=data.get("stated_priority", "unspecified"),
        routing_expertise=data.get("routing_expertise", "unspecified"),
    )
