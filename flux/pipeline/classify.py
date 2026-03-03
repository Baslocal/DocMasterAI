"""
DocMaster — Stage 2: Document Classification
MobileNetV3-Small ONNX classifier — CPU inference < 100ms

Model: /opt/docmaster/models/classifier/doc_classifier_v1.onnx
Runtime: ONNX Runtime (onnxruntime==1.17.0) — CPU only (onnxruntime-gpu for GPU deployments)
Output: doc_type, confidence, is_handwritten, has_table, has_stamp, use_color_ocr, recommended_engine

Low-confidence fallback: < 0.60 → classify as 'unknown', use generic schema
"""
import numpy as np

# Map classifier output index → document_type enum value
# STRICT RULE: these values must match dm_core.document_type enum exactly
LABEL_MAP = {
    0: "deed",
    1: "invoice",
    2: "form",
    3: "handwritten",
    4: "table",
    5: "mixed",
    6: "unknown",
}

LOW_CONFIDENCE_THRESHOLD = 0.60


def classify_document(page_image, onnx_session) -> dict:
    """
    Run ONNX classifier on first page image.

    Args:
        page_image: numpy array (H, W, C) or (H, W) — first page of document
        onnx_session: loaded ONNX InferenceSession, or None if model not available

    Returns:
        classification dict with doc_type, confidence, routing flags
    """
    if onnx_session is None or page_image is None:
        return _unknown_result("Classifier not available")

    try:
        # Preprocess for MobileNetV3-Small: 224x224, normalized
        import cv2
        if len(page_image.shape) == 2:
            page_image = cv2.cvtColor(page_image, cv2.COLOR_GRAY2BGR)
        img = cv2.resize(page_image, (224, 224))
        img = img.astype(np.float32) / 255.0
        img = (img - np.array([0.485, 0.456, 0.406])) / np.array([0.229, 0.224, 0.225])
        img = np.transpose(img, (2, 0, 1))  # HWC → CHW
        img = np.expand_dims(img, axis=0)   # Add batch dim

        # Run inference
        input_name = onnx_session.get_inputs()[0].name
        outputs = onnx_session.run(None, {input_name: img.astype(np.float32)})
        logits = outputs[0][0]

        # Softmax
        exp_logits = np.exp(logits - np.max(logits))
        probs = exp_logits / exp_logits.sum()

        top_idx = int(np.argmax(probs))
        confidence = float(probs[top_idx])
        doc_type = LABEL_MAP.get(top_idx, "unknown")

        # Low-confidence fallback
        if confidence < LOW_CONFIDENCE_THRESHOLD:
            return _unknown_result(f"Low confidence: {confidence:.2f}")

        # Derive routing flags from classification
        is_handwritten = doc_type == "handwritten"
        has_table = doc_type == "table"
        recommended_engine = _select_engine(doc_type, is_handwritten, has_table)

        return {
            "doc_type": doc_type,
            "confidence": confidence,
            "is_handwritten": is_handwritten,
            "has_table": has_table,
            "has_stamp": False,         # Stamp detection: future enhancement
            "use_color_ocr": False,     # Color OCR: future enhancement
            "recommended_engine": recommended_engine,
        }

    except Exception as e:
        return _unknown_result(f"Classifier error: {e}")


def _unknown_result(reason: str) -> dict:
    return {
        "doc_type": "unknown",
        "confidence": 0.0,
        "is_handwritten": False,
        "has_table": False,
        "has_stamp": False,
        "use_color_ocr": False,
        "recommended_engine": "tesseract",
        "fallback_reason": reason,
    }


def _select_engine(doc_type: str, is_handwritten: bool, has_table: bool) -> str:
    """Select primary OCR engine based on classification flags.

    Engine routing table (from Phase 3 spec):
      Handwritten                → kraken (fallback: olmocr)
      Table                     → paddle (PP-Structure)
      Modern printed (default)  → tesseract (fallback: paddle)
    """
    if is_handwritten:
        return "kraken"
    if has_table:
        return "paddle"
    return "tesseract"
