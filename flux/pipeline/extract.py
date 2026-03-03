"""
DocMaster — Stage 4: LLM Extraction
Parses OCR text into structured named fields using local Ollama LLM.

STRICT RULES (non-negotiable):
  - temperature: 0.0 ALWAYS — ensures deterministic output for audit trail
  - format: "json" ALWAYS — prevents markdown fences breaking JSON parsing
  - model: llama3.1:8b-q4_K_M (configurable via system_config)

Review status logic: document is marked 'review' if ANY SINGLE required field
has confidence below review_threshold (default 75%) — not just the mean.
"""
import json
import re
from typing import Any

import httpx

# Fixed system prompt — do not modify without testing on representative samples
SYSTEM_PROMPT = """You are a precise document data extraction assistant. You extract specific information from OCR-processed documents.

Rules:
1. Extract ONLY information explicitly present in the document text
2. Do NOT invent, infer, or assume values not in the text
3. If a field is not found, set its value to null
4. Return ONLY valid JSON — no preamble, no explanation, no markdown fences
5. Dates must be in YYYY-MM-DD format
6. Preserve exact spelling found in the document for names and addresses"""

REVIEW_THRESHOLD = 0.75  # Overridden at runtime by dm_vault.system_config


def _build_user_prompt(ocr_text: str, schema: dict) -> str:
    """Build dynamic extraction prompt from document schema."""
    doc_type = schema.get("doc_type", "unknown")
    fields = schema.get("fields", [])

    field_descriptions = "\n".join(
        f"  - {f['name']} ({f.get('display_name', f['name'])}): "
        f"{f.get('description', '')} {'[REQUIRED]' if f.get('required') else '[optional]'}"
        + (f" Example: {f['example']}" if f.get("example") else "")
        for f in fields
    )

    field_structure = json.dumps(
        {"fields": [{"name": f["name"], "value": "...", "confidence": 0.0, "source_page": 1} for f in fields]},
        indent=2,
    )

    return f"""Extract the following fields from this {doc_type} document:

{field_descriptions}

Document text (OCR output):
---
{ocr_text[:6000]}
---

Return a JSON object with this exact structure:
{field_structure}

Confidence scoring guide:
- 0.90–1.00: Value found clearly and unambiguously
- 0.75–0.89: Value found but required minor interpretation
- 0.60–0.74: Value inferred from context
- Below 0.60: Very uncertain — flag for human review"""


async def run_extraction(
    ocr_text: str,
    schema: dict,
    doc_type: str,
    ollama_host: str,
    model: str,
    review_threshold: float = REVIEW_THRESHOLD,
) -> tuple[list[dict], float, bool]:
    """
    Run LLM extraction and return structured field results.

    Returns:
        extractions: list of field dicts with name, value, confidence, order
        mean_confidence: mean confidence across all fields
        needs_review: True if any required field confidence < review_threshold
    """
    if not schema or not schema.get("fields"):
        # No schema — extract as plain content
        return _plain_content_extraction(ocr_text), 0.65, True

    user_prompt = _build_user_prompt(ocr_text, schema)

    async with httpx.AsyncClient(timeout=120.0) as client:
        resp = await client.post(
            f"{ollama_host}/api/chat",
            json={
                "model": model,
                "messages": [
                    {"role": "system", "content": SYSTEM_PROMPT},
                    {"role": "user", "content": user_prompt},
                ],
                "format": "json",      # MANDATORY — never remove
                "stream": False,
                "options": {
                    "temperature": 0.0,    # MANDATORY — never change
                    "num_ctx": 8192,
                },
            },
        )

    if resp.status_code != 200:
        raise RuntimeError(f"DM_3010: Ollama API error: HTTP {resp.status_code}")

    raw_content = resp.json()["message"]["content"]
    return _parse_and_validate(raw_content, schema, review_threshold)


def _parse_and_validate(
    raw_json: str,
    schema: dict,
    review_threshold: float,
) -> tuple[list[dict], float, bool]:
    """Validate LLM output against schema. Raise on critical failures."""
    try:
        data = json.loads(raw_json)
    except json.JSONDecodeError as e:
        raise ValueError(f"DM_3011: LLM returned invalid JSON: {e}")

    fields_data = data.get("fields", [])
    if not isinstance(fields_data, list):
        raise ValueError("DM_3012: LLM response missing 'fields' array")

    schema_fields = {f["name"]: f for f in schema.get("fields", [])}
    extractions = []
    confidences = []
    needs_review = False

    for i, field_result in enumerate(fields_data):
        name = field_result.get("name")
        value = field_result.get("value")
        confidence = float(field_result.get("confidence", 0.5))

        # Clamp confidence to valid range
        confidence = max(0.0, min(1.0, confidence))

        # Validate date fields
        schema_field = schema_fields.get(name, {})
        if schema_field.get("type") == "date" and value:
            if not re.match(r"^\d{4}-\d{2}-\d{2}$", str(value)):
                value = None  # Clear non-conforming date
                confidence = 0.0

        confidences.append(confidence)

        # Check if any required field is below review threshold
        if schema_field.get("required") and confidence < review_threshold:
            needs_review = True

        extractions.append({
            "name": name,
            "value": str(value) if value is not None else None,
            "confidence": confidence,
            "order": i,
        })

    mean_confidence = sum(confidences) / len(confidences) if confidences else 0.0

    # Check all required schema fields are present
    for field in schema.get("fields", []):
        if field.get("required"):
            present = any(e["name"] == field["name"] for e in extractions)
            if not present:
                extractions.append({
                    "name": field["name"],
                    "value": None,
                    "confidence": 0.0,
                    "order": len(extractions),
                })
                needs_review = True

    return extractions, mean_confidence, needs_review


def _plain_content_extraction(ocr_text: str) -> list[dict]:
    """Fallback for unknown/handwritten schemas — single content field."""
    return [{"name": "content", "value": ocr_text, "confidence": 0.65, "order": 0}]
