"""
DocMaster — Stage 1: Pre-Processing
Converts any supported input format to clean, consistent PNG images at 300 DPI.

Steps:
  1.1  Format normalization (PDF → pdftoppm, TIFF frame split, HEIC decode, etc.)
  1.2  Orientation detection and correction (Tesseract OSD)
  1.3  Deskewing (Probabilistic Hough Transform, ±10° gate)
  1.4  Denoising (fastNlMeansDenoising or medianBlur for fax)
  1.5  Binarization (Sauvola adaptive threshold, skip if use_color_ocr=True)

STRICT RULE: Never alter binarization parameters without testing on representative samples.
Sauvola window_size=25, k=0.2 at 300 DPI is the validated configuration.
"""
import os
import subprocess
from pathlib import Path
from typing import Optional

import cv2
import numpy as np
from PIL import Image


async def preprocess_document(
    file_path: str,
    job_dir: Path,
    use_color_ocr: bool = False,
) -> tuple[list[np.ndarray], int]:
    """
    Convert input document to pre-processed page images.

    Returns:
        pages: list of numpy arrays (BGR for color, grayscale for binarized)
        page_count: number of pages
    """
    job_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    pages_dir = job_dir / "pages"
    preprocessed_dir = job_dir / "preprocessed"
    pages_dir.mkdir(exist_ok=True)
    preprocessed_dir.mkdir(exist_ok=True)

    # Step 1.1: Format normalization
    raw_pages = await _normalize_format(file_path, pages_dir)
    page_count = len(raw_pages)

    # Steps 1.2–1.5: Process each page
    processed_pages = []
    for i, page_path in enumerate(raw_pages):
        img = cv2.imread(str(page_path))
        if img is None:
            continue

        # 1.2 Orientation
        img = _correct_orientation(img)

        # 1.3 Deskew
        img = _deskew(img)

        # 1.4 Denoise
        is_fax = "fax" in str(file_path).lower()
        img = _denoise(img, is_fax=is_fax)

        # 1.5 Binarize (skip for color-sensitive documents)
        if not use_color_ocr:
            img = _binarize_sauvola(img)

        out_path = preprocessed_dir / f"page_{i+1:03d}.png"
        cv2.imwrite(str(out_path), img)
        processed_pages.append(img)

    return processed_pages, page_count


async def _normalize_format(file_path: str, pages_dir: Path) -> list[Path]:
    """Convert all supported formats to individual PNG files in pages_dir."""
    file_path = Path(file_path)
    ext = file_path.suffix.lower()

    if ext == ".pdf":
        return _pdf_to_pages(file_path, pages_dir)
    elif ext in (".tif", ".tiff"):
        return _tiff_to_pages(file_path, pages_dir)
    elif ext in (".heic", ".heif"):
        return _heic_to_page(file_path, pages_dir)
    else:
        # Single image — copy as page_001.png
        out = pages_dir / "page_001.png"
        img = cv2.imread(str(file_path))
        if img is not None:
            cv2.imwrite(str(out), img)
        return [out]


def _pdf_to_pages(pdf_path: Path, pages_dir: Path) -> list[Path]:
    """Rasterize PDF to PNG at 300 DPI using pdftoppm."""
    prefix = str(pages_dir / "page")
    result = subprocess.run(
        ["pdftoppm", "-r", "300", "-png", str(pdf_path), prefix],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"DM_3001: pdftoppm failed: {result.stderr}")
    return sorted(pages_dir.glob("page-*.png"))


def _tiff_to_pages(tiff_path: Path, pages_dir: Path) -> list[Path]:
    """Split multi-page TIFF and upsample to 300 DPI."""
    pages = []
    with Image.open(str(tiff_path)) as img:
        for i in range(getattr(img, "n_frames", 1)):
            img.seek(i)
            frame = img.convert("RGB")
            # Upsample fax TIFFs from 200 DPI to 300 DPI
            dpi = img.info.get("dpi", (200, 200))
            if dpi[0] < 300:
                scale = 300 / dpi[0]
                new_size = (int(frame.width * scale), int(frame.height * scale))
                frame = frame.resize(new_size, Image.LANCZOS)
            out = pages_dir / f"page_{i+1:03d}.png"
            frame.save(str(out))
            pages.append(out)
    return pages


def _heic_to_page(heic_path: Path, pages_dir: Path) -> list[Path]:
    """Decode HEIC/HEIF using pyheif."""
    import pyheif
    heif_file = pyheif.read(str(heic_path))
    img = Image.frombytes(
        heif_file.mode, heif_file.size, heif_file.data,
        "raw", heif_file.mode, heif_file.stride,
    )
    out = pages_dir / "page_001.png"
    img.save(str(out))
    return [out]


def _correct_orientation(img: np.ndarray) -> np.ndarray:
    """Detect and correct page rotation using Tesseract OSD."""
    try:
        import pytesseract
        from pytesseract import Output
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        osd = pytesseract.image_to_osd(gray, output_type=Output.DICT)
        rotation = osd.get("rotate", 0)
        confidence = osd.get("orientation_conf", 0)

        if rotation != 0 and confidence >= 1.5:
            h, w = img.shape[:2]
            center = (w // 2, h // 2)
            M = cv2.getRotationMatrix2D(center, -rotation, 1.0)
            img = cv2.warpAffine(img, M, (w, h), flags=cv2.INTER_LANCZOS4)
    except Exception:
        pass  # OSD failure — leave original orientation
    return img


def _deskew(img: np.ndarray) -> np.ndarray:
    """Correct scanner placement skew using Probabilistic Hough Transform."""
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY) if len(img.shape) == 3 else img
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    edges = cv2.Canny(binary, 50, 150, apertureSize=3)
    lines = cv2.HoughLinesP(edges, 1, np.pi / 180, threshold=100, minLineLength=100, maxLineGap=10)

    if lines is None:
        return img

    angles = []
    for line in lines:
        x1, y1, x2, y2 = line[0]
        angle = np.degrees(np.arctan2(y2 - y1, x2 - x1))
        if -10 <= angle <= 10:  # Gate: only correct if within ±10 degrees
            angles.append(angle)

    if not angles:
        return img

    median_angle = np.median(angles)
    if abs(median_angle) < 0.1:
        return img

    h, w = img.shape[:2]
    center = (w // 2, h // 2)
    M = cv2.getRotationMatrix2D(center, median_angle, 1.0)
    return cv2.warpAffine(img, M, (w, h), flags=cv2.INTER_LANCZOS4, borderMode=cv2.BORDER_REPLICATE)


def _denoise(img: np.ndarray, is_fax: bool = False) -> np.ndarray:
    """Remove noise appropriate to document origin."""
    if len(img.shape) == 3:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    else:
        gray = img

    if is_fax:
        # Fax compression artifacts — mild median blur
        return cv2.medianBlur(gray, 3)
    else:
        # Scanner grain and aged paper — fastNlMeansDenoising
        # h=10 is the validated value — do not increase above 15
        return cv2.fastNlMeansDenoising(gray, h=10)


def _binarize_sauvola(img: np.ndarray) -> np.ndarray:
    """Sauvola adaptive binarization — effective for non-uniform illumination and aged paper.

    Parameters:
        window_size=25: validated at 300 DPI — do not change without testing
        k=0.2: Sauvola k parameter — controls local threshold sensitivity
    """
    from skimage.filters import threshold_sauvola

    if len(img.shape) == 3:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    else:
        gray = img

    thresh = threshold_sauvola(gray, window_size=25, k=0.2)
    binary = (gray > thresh).astype(np.uint8) * 255
    return binary
