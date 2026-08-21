import os
from typing import Optional

from openai import OpenAI
from models import RequirementVector, InfraPreference, ChurnProfile, MaintenancePreference, BgpExpertise, CostSensitivity, RecommendationResult

_client: Optional[OpenAI] = None
_MODEL = "gpt-5.6-luna"
_GATEWAY_BASE_URL = "https://factchat-cloud.mindlogic.ai/v1/gateway"

_SYSTEM_PROMPT = (
    "You are NaRo (Native Routing advisor), an expert system that helps Kubernetes operators choose the optimal "
    "native routing configuration for public cloud deployments. "
    "You analyze operator requirements and extract structured parameters to feed into a decision framework. "
    "Be conservative when inferring values — if the operator does not mention BGP expertise, assume beginner. "
    "If cluster size is not mentioned, ask for clarification; do not guess."
)

_EXTRACT_TOOL = {
    "type": "function",
    "function": {
        "name": "extract_requirements",
        "description": (
            "Extract structured Kubernetes native routing requirements from the operator's "
            "natural language description."
        ),
        "parameters": {
            "type": "object",
            "properties": {
                "scale": {
                    "type": "integer",
                    "description": (
                        "Expected number of worker nodes. If a range is given, use the upper bound. "
                        "If the description does not state or imply the cluster size, set scale to 0, "
                        "set clarification_needed to true, and put a question for the operator in "
                        "clarification_question."
                    ),
                },
                "clarification_needed": {
                    "type": "boolean",
                    "description": (
                        "True only if a field required for feasibility filtering (cluster size) "
                        "is missing from the description and cannot be inferred. Default false."
                    ),
                },
                "clarification_question": {
                    "type": "string",
                    "description": "The clarification question to ask the operator when clarification_needed is true.",
                },
                "native_required": {
                    "type": "boolean",
                    "description": (
                        "Whether unencapsulated (native) pod routing is a hard requirement — "
                        "e.g., the operator prohibits encapsulation/overlay, needs pod IP "
                        "transparency to external systems, or has MTU/on-prem interconnect "
                        "constraints. Default false if not mentioned."
                    ),
                },
                "infra": {
                    "type": "string",
                    "enum": ["gke", "self_managed", "any"],
                    "description": (
                        "'gke' for Google Kubernetes Engine, "
                        "'self_managed' for kubeadm/custom cluster, "
                        "'any' if no preference."
                    ),
                },
                "maintenance": {
                    "type": "string",
                    "enum": ["low", "medium", "high"],
                    "description": (
                        "Routing-control preference (paper: delegated/neutral/direct-control): 'low' if the team wants "
                        "hands-off, provider-delegated L3 operation; 'high' if it wants to "
                        "own routing operation for direct control and optimization "
                        "(e.g., needs control-plane or version control the provider withholds); "
                        "'medium' if neutral or not mentioned."
                    ),
                },
                "bgp_expertise": {
                    "type": "string",
                    "enum": ["beginner", "intermediate", "expert"],
                    "description": "Operator's routing-operations expertise (cloud routing automation and BGP); r_expert in the paper.",
                },
                "cost_sensitivity": {
                    "type": "string",
                    "enum": ["cost_first", "balanced", "perf_first"],
                    "description": (
                        "'cost_first' if minimizing spend is top priority, "
                        "'perf_first' if performance is top priority, "
                        "'balanced' otherwise."
                    ),
                },
            },
            "required": ["scale", "native_required", "infra", "maintenance", "bgp_expertise", "cost_sensitivity"],
        },
    },
}


class ClarificationNeeded(Exception):
    """Raised when a filtering-critical field (cluster size) is missing from the input."""

    def __init__(self, question: str):
        self.question = question
        super().__init__(question)


def _get_client() -> OpenAI:
    global _client
    if _client is None:
        api_key = os.environ.get("GATEWAY_API_KEY")
        if not api_key:
            raise ValueError("GATEWAY_API_KEY environment variable is not set")
        _client = OpenAI(api_key=api_key, base_url=_GATEWAY_BASE_URL)
    return _client


def extract_requirements(text: str) -> RequirementVector:
    """Use Claude via gateway to parse natural language into a structured RequirementVector."""
    client = _get_client()

    response = client.chat.completions.create(
        model=_MODEL,
        messages=[
            {"role": "system", "content": _SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Extract the deployment requirements from the following operator description:\n\n{text}",
            },
        ],
        tools=[_EXTRACT_TOOL],
        tool_choice={"type": "function", "function": {"name": "extract_requirements"}},
    )

    tool_call = response.choices[0].message.tool_calls[0]
    import json
    data = json.loads(tool_call.function.arguments)

    if data.get("clarification_needed") or int(data.get("scale", 0)) <= 0:
        raise ClarificationNeeded(
            data.get("clarification_question")
            or "How many worker nodes do you expect the cluster to run?"
        )

    return RequirementVector(
        scale=int(data["scale"]),
        native_required=bool(data.get("native_required", False)),
        infra=InfraPreference(data["infra"]),
        maintenance=MaintenancePreference(data.get("maintenance", "medium")),
        bgp_expertise=BgpExpertise(data["bgp_expertise"]),
        cost_sensitivity=CostSensitivity(data["cost_sensitivity"]),
    )


def generate_explanation(result: RecommendationResult, original_text: Optional[str] = None) -> str:
    """Use Claude via gateway to generate a natural language explanation of the recommendation."""
    client = _get_client()

    req = result.extracted_requirements
    req_summary = (
        f"- Cluster scale: {req.scale} nodes\n"
        f"- Native routing required: {req.native_required}\n"
        f"- Infrastructure preference: {req.infra.value}\n"
        f"- Routing-control preference: {req.maintenance.value}\n"
        f"- BGP expertise: {req.bgp_expertise.value}\n"
        f"- Cost--performance priority: {req.cost_sensitivity.value}"
    ) if req else "(structured input)"

    eliminated = [s for s in result.scores if s.eliminated]
    scored = [s for s in result.scores if not s.eliminated]
    eliminated_summary = "\n".join(
        f"  - {s.config_id} ({s.name}): {s.elimination_reason}" for s in eliminated
    ) or "  None"
    scored_summary = "\n".join(
        f"  - {s.config_id} ({s.name}): TOPSIS score {s.topsis_score:.3f} (rank {s.rank})"
        for s in scored
    )
    subparam_summary = "\n".join(
        f"  - {p.label}: {p.selected_value} — {p.selected_description}"
        for p in result.sub_parameters
    ) or "  (no sub-parameters)"

    context = f"""
Operator requirements:
{req_summary}

Eliminated configurations (hard constraints):
{eliminated_summary}

TOPSIS scores (feasible configurations):
{scored_summary}

Recommended: {result.recommended_config} ({result.recommended_name})

Optimized sub-parameters:
{subparam_summary}
"""

    if original_text:
        context = f"Operator's original description:\n\"{original_text}\"\n\n" + context

    prompt = (
        "Generate a concise (3–5 sentences) natural language explanation of this "
        "native routing configuration recommendation. "
        "Explain why the recommended configuration was chosen, what the key trade-offs were, "
        "and highlight any important sub-parameter decisions. "
        "Write for a Kubernetes operator who may not be familiar with TOPSIS scoring.\n\n"
        + context
    )

    response = client.chat.completions.create(
        model=_MODEL,
        messages=[
            {"role": "system", "content": _SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
    )

    return response.choices[0].message.content.strip()
