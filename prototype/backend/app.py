import os
import sys
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse

# Allow imports from this directory
sys.path.insert(0, str(Path(__file__).parent))

from config import CONFIG_META
import extract_v2
import explain_v2
import pipeline_v2

app = FastAPI(title="NARO (NAtive ROuting advisor)", version="1.0.0")

STATIC_DIR = Path(__file__).parent.parent / "static"


@app.post("/api/v2/recommend")
def recommend_v2(body: pipeline_v2.OperatorInputV2):
    """Revised pipeline: structured form merged with an optional free-form request.

    Implements the paper's Section 4: extraction (LLM, only if freeform_text is
    given), merging with precedence and conflict detection, the five feasibility
    rules, and importance-level TOPSIS. No deployment-parameter stage.
    """
    extracted = None
    if body.freeform_text:
        if not os.environ.get("GATEWAY_API_KEY"):
            raise HTTPException(status_code=503, detail="GATEWAY_API_KEY is not configured; free-form input requires it.")
        try:
            extracted = extract_v2.extract(body.freeform_text)
        except extract_v2.ClarificationNeeded as e:
            return {"clarification_needed": True, "question": e.question}
        except Exception as e:
            raise HTTPException(status_code=422, detail=f"Requirement extraction failed: {e}")
    try:
        merged = pipeline_v2.merge(body.form, extracted)
        result = pipeline_v2.run(merged, body.form)
    except pipeline_v2.ClarificationNeeded as e:
        return {"clarification_needed": True, "question": e.question}
    result["interpreted"] = {
        "scale": merged.scale,
        "transparency_required": merged.transparency_required,
        "self_managed_required": merged.self_managed_required,
        "budget_limit_usd": merged.budget_limit_usd,
        "pod_renumbering": merged.pod_renumbering,
        "stated_priority": merged.priority,
        "routing_expertise": merged.routing_expertise,
    }
    if not result.get("infeasible"):
        result["extracted"] = extracted.as_dict() if extracted else None
        if os.environ.get("GATEWAY_API_KEY"):
            try:
                feasible_ids = [k for k, v in pipeline_v2.NAME.items() if v not in result["eliminated"]]
                result["explanation"] = explain_v2.generate(merged, result, feasible_ids, body.freeform_text)
            except Exception as e:
                result["explanation"] = f"(Explanation unavailable: {e})"
    return result


@app.get("/api/configs")
def list_configs():
    """Return configuration metadata for UI display."""
    return CONFIG_META


@app.get("/api/health")
def health():
    return {"status": "ok", "llm_enabled": bool(os.environ.get("GATEWAY_API_KEY"))}


# Serve frontend static files
if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")

    @app.get("/")
    def root():
        return FileResponse(str(STATIC_DIR / "index.html"))
