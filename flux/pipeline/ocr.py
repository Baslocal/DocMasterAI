"""
DocMaster — Stage 3: OCR Execution
Engine selection, fallback logic, and multi-page merging.

Engine routing table:
  Handwritten                → Kraken (fallback: olmOCR via Qwen2.5-VL)
  Table                     → PaddleOCR PP-Structure (fallback: Tesseract)
  Modern printed (default)  → Tesseract 5 (fallback: PaddleOCR)
  Primary confidence < 75%  → Run fallback engine

STRICT RULE: PaddleOCR MUST use local model paths — no internet auto-download.
Set PADDLE_PDX_CACHE_HOME=/opt/docmaster/models/paddleocr
"""
import os
from pathlib import Path

import numpy as np

PADDLE_MODEL_BASE = os.getenv("PADDLE_PDX_CACHE_HOME", "/opt/docmaster/models/paddleocr")
KRAKEN_MODEL_BASE = os.getenv("KRAKEN_MODEL_PATH", "/opt/docmaster/models/kraken")
OLLAMA_HOST = os.getenv("OLLAMA_HOST", "http://127.0.0.1:11434")
OCR_FALLBACK_THRESHOLD = float(os.getenv("OCR_FALLBACK_THRESHOLD", "0.75"))


async def run_ocr(
    pages: list[np.ndarray],
    classification: dict,
    job_dir: Path,
) -> tuple[str, str]:
    """
    Run OCR across all pages and return merged text with page markers.

    Returns:
        merged_text: Full OCR output with '=== PAGE N OF M ===' markers
        engine_used: Name of the engine that produced the final output
    """
    ocr_dir = job_dir / "ocr_raw"
    ocr_dir.mkdir(exist_ok=True)

    total_pages = len(pages)
    page_texts = []
    engine_used = classification.get("recommended_engine", "tesseract")

    for i, page_img in enumerate(pages):
        page_num = i + 1
        text, confidence, engine_name = await _run_page_ocr(
            page_img, page_num, classification, ocr_dir
        )
        page_texts.append((page_num, text))

        # Write per-page OCR output
        (ocr_dir / f"page_{page_num:03d}.txt").write_text(text)
        engine_used = engine_name

    # Merge all pages
    merged = _merge_pages(page_texts, total_pages)
    (job_dir / "ocr_merged.txt").write_text(merged)

    return merged, engine_used


async def _run_page_ocr(
    page_img: np.ndarray,
    page_num: int,
    classification: dict,
    ocr_dir: Path,
) -> tuple[str, float, str]:
    """Run OCR on a single page with engine selection and fallback."""
    is_handwritten = classification.get("is_handwritten", False)
    has_table = classification.get("has_table", False)
    recommended = classification.get("recommended_engine", "tesseract")

    if is_handwritten:
        text, confidence = _run_kraken(page_img)
        if confidence < OCR_FALLBACK_THRESHOLD:
            olmocr_text = await _run_olmocr(page_img)
            if olmocr_text:
                return olmocr_text, 0.65, "olmocr"
        return text, confidence, "kraken"

    if has_table:
        text, confidence = _run_paddle_structure(page_img)
        if confidence < OCR_FALLBACK_THRESHOLD:
            fallback_text, fallback_conf = _run_tesseract(page_img, ocr_dir, page_num)
            return fallback_text, fallback_conf, "tesseract"
        return text, confidence, "paddle"

    # Default: Tesseract with PaddleOCR fallback
    text, confidence = _run_tesseract(page_img, ocr_dir, page_num)
    if confidence < OCR_FALLBACK_THRESHOLD:
        paddle_text, paddle_conf = _run_paddle(page_img)
        if paddle_conf > confidence:
            return paddle_text, paddle_conf, "paddle"
    return text, confidence, "tesseract"


def _run_tesseract(
    img: np.ndarray,
    ocr_dir: Path,
    page_num: int,
) -> tuple[str, float]:
    """Tesseract 5 — primary engine for modern printed documents."""
    import pytesseract
    from pytesseract import Output

    custom_config = r"--oem 3 --psm 3"

    try:
        # Word-level data for confidence calculation
        data = pytesseract.image_to_data(img, config=custom_config, output_type=Output.DICT)
        confs = [c for c in data["conf"] if c != -1]
        confidence = (sum(confs) / len(confs) / 100) if confs else 0.0

        # Generate hOCR for bounding box data (used by document detail modal)
        hocr = pytesseract.image_to_pdf_or_hocr(img, config=custom_config, extension="hocr")
        (ocr_dir / f"page_{page_num:03d}.hocr").write_bytes(hocr)

        text = pytesseract.image_to_string(img, config=custom_config)
        return text.strip(), confidence

    except Exception as e:
        return "", 0.0


def _run_paddle(img: np.ndarray) -> tuple[str, float]:
    """PaddleOCR — fallback for printed documents and multilingual text.
    STRICT RULE: Must use local model paths — no internet auto-download.
    """
    try:
        from paddleocr import PaddleOCR

        ocr = PaddleOCR(
            use_angle_cls=True,
            lang="en",
            det_model_dir=f"{PADDLE_MODEL_BASE}/en/det",
            rec_model_dir=f"{PADDLE_MODEL_BASE}/en/rec",
            cls_model_dir=f"{PADDLE_MODEL_BASE}/en/cls",
            show_log=False,
        )
        result = ocr.ocr(img, cls=True)
        if not result or not result[0]:
            return "", 0.0

        texts = []
        confs = []
        for line in result[0]:
            if line and len(line) >= 2:
                texts.append(line[1][0])
                confs.append(line[1][1])

        confidence = sum(confs) / len(confs) if confs else 0.0
        return "\n".join(texts), confidence

    except Exception:
        return "", 0.0


def _run_paddle_structure(img: np.ndarray) -> tuple[str, float]:
    """PaddleOCR PP-Structure — table extraction with cell-level boundaries."""
    try:
        from paddleocr import PPStructure

        engine = PPStructure(
            table=True, ocr=True, show_log=False,
            layout_model_dir=f"{PADDLE_MODEL_BASE}/layout",
            table_model_dir=f"{PADDLE_MODEL_BASE}/table",
        )
        result = engine(img)
        texts = []
        for region in result:
            if region.get("type") == "table":
                texts.append(region.get("res", {}).get("html", ""))
            else:
                texts.append(str(region.get("res", "")))
        return "\n".join(texts), 0.80

    except Exception:
        return "", 0.0


def _run_kraken(img: np.ndarray) -> tuple[str, float]:
    """Kraken — handwritten documents and historical scripts.
    STRICT RULE: Uses vendored models only — no model downloads at runtime.
    """
    try:
        from kraken import blla, rpred
        from kraken.lib import models as kraken_models
        from PIL import Image
        import cv2

        model_path = f"{KRAKEN_MODEL_BASE}/en_best.mlmodel"
        model = kraken_models.load_any(model_path)

        # Convert numpy array to PIL Image
        if len(img.shape) == 2:
            pil_img = Image.fromarray(img)
        else:
            pil_img = Image.fromarray(cv2.cvtColor(img, cv2.COLOR_BGR2RGB))

        baseline_seg = blla.segment(pil_img)
        records = list(rpred.rpred(model, pil_img, baseline_seg))
        text = "\n".join(str(r) for r in records)
        return text, 0.70

    except Exception:
        return "", 0.0


async def _run_olmocr(img: np.ndarray) -> str:
    """olmOCR via Qwen2.5-VL through Ollama — last-resort engine.
    Fixed confidence: 0.65 (always triggers 'review' status).
    """
    import base64
    import cv2
    import httpx

    try:
        _, buffer = cv2.imencode(".png", img)
        b64_img = base64.b64encode(buffer.tobytes()).decode("utf-8")

        async with httpx.AsyncClient(timeout=180.0) as client:
            resp = await client.post(
                f"{OLLAMA_HOST}/api/generate",
                json={
                    "model": "qwen2.5-vl:7b",
                    "prompt": (
                        "Transcribe all text exactly as it appears in this scanned document. "
                        "Preserve line breaks. Do not interpret or correct. "
                        "Output raw transcription only."
                    ),
                    "images": [b64_img],
                    "stream": False,
                },
            )

        if resp.status_code == 200:
            return resp.json().get("response", "")
    except Exception:
        pass
    return ""


def _merge_pages(page_texts: list[tuple[int, str]], total: int) -> str:
    """Merge per-page OCR output with structured page markers."""
    parts = []
    for page_num, text in page_texts:
        parts.append(f"=== PAGE {page_num} OF {total} ===\n\n{text}")
    return "\n\n".join(parts)
