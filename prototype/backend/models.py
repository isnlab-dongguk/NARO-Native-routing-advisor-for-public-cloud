from pydantic import BaseModel, Field, field_validator
from typing import Dict, List, Optional
from enum import Enum


class InfraPreference(str, Enum):
    gke = "gke"
    self_managed = "self_managed"
    any = "any"


class ChurnProfile(str, Enum):
    """Node churn profile: 'none' = stable node set (no autoscaling);
    'planned' = autoscaler-driven graceful scale events; 'unplanned' =
    frequent involuntary terminations (preemptible/Spot VMs)."""
    none = "none"
    planned = "planned"
    unplanned = "unplanned"


class BgpExpertise(str, Enum):
    beginner = "beginner"
    intermediate = "intermediate"
    expert = "expert"


# Paper labels: low = delegated, medium = neutral, high = direct-control
class MaintenancePreference(str, Enum):
    low = "low"
    medium = "medium"
    high = "high"


class CostSensitivity(str, Enum):
    cost_first = "cost_first"
    balanced = "balanced"
    perf_first = "perf_first"


class PerfPriority(str, Enum):
    latency = "latency"
    throughput = "throughput"
    general = "general"


class RequirementVector(BaseModel):
    scale: int = Field(..., ge=1, description="Expected cluster node count")
    # Dropped from the paper schema (node-event handling c2 is now a static
    # criterion); kept optional for backward compatibility. Unused by scoring.
    autoscale: ChurnProfile = Field(default=ChurnProfile.none, description="Deprecated; unused")

    @field_validator("autoscale", mode="before")
    @classmethod
    def _coerce_autoscale_bool(cls, v):
        # Backward compatibility with the former Boolean field
        if isinstance(v, bool):
            return "planned" if v else "none"
        return v
    native_required: bool = Field(
        False,
        description="Is unencapsulated (native) pod routing a hard requirement? "
                    "(e.g., encapsulation prohibited, pod IP transparency, MTU or on-prem interconnect constraints)",
    )
    infra: InfraPreference = Field(..., description="Infrastructure control preference")
    maintenance: MaintenancePreference = Field(
        MaintenancePreference.medium,
        description="Routing-control preference: 'low' = delegate routing "
                    "operation to the provider (hands-off), 'high' = own it for "
                    "direct control and optimization, 'medium' = neutral",
    )
    bgp_expertise: BgpExpertise = Field(..., description="Operator BGP expertise level")
    cost_sensitivity: CostSensitivity = Field(..., description="Cost priority")
    # Dropped from the paper schema (no latency criterion); kept optional
    # for backward compatibility with existing clients. Unused by scoring.
    perf_priority: PerfPriority = Field(default=PerfPriority.general, description="Deprecated; unused")


class NLPRequest(BaseModel):
    text: str = Field(..., description="Free-form natural language requirement description")


class ConfigScore(BaseModel):
    config_id: str
    name: str
    topsis_score: float
    distance_positive: float
    distance_negative: float
    rank: int
    eliminated: bool
    elimination_reason: Optional[str] = None


class SubParameter(BaseModel):
    key: str
    label: str
    selected_value: str
    selected_description: str
    all_options: Dict[str, str]


class RecommendationResult(BaseModel):
    recommended_config: str
    recommended_name: str
    config_description: str
    scores: List[ConfigScore]
    sub_parameters: List[SubParameter]
    weight_preset_used: str
    weights_used: List[float]
    criteria_names: List[str]
    explanation: Optional[str] = None
    extracted_requirements: Optional[RequirementVector] = None
