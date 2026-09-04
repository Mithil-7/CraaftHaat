"""
CraftHaat — AI Engine
========================
Wraps the full self-hosted AI pipeline used by /api/v1/process-catalog:

    1. Image background removal        -> rembg (RMBG-1.4 session)
    2. Speech-to-text (regional audio)  -> faster-whisper
    3. Catalog + pricing generation     -> local Ollama (qwen2.5:3b-instruct)
    4. Text embedding for pgvector      -> sentence-transformers (BAAI/bge-m3)

Setup (run once):
    pip install -r requirements.txt

    # Pull the LLM into your local Ollama daemon:
    ollama pull qwen2.5:3b-instruct
    ollama serve   # if not already running as a service

    # rembg will auto-download the RMBG-1.4 / u2net weights to ~/.u2net on
    # first run. To pre-fetch RMBG-1.4 explicitly:
    #   python -c "from rembg import new_session; new_session('birefnet-general')"
    # (rembg's model name for RMBG-1.4-equivalent quality is 'birefnet-general';
    #  swap the MODEL_NAME constant below if you have the exact 'rmbg-1.4' onnx
    #  weights registered as a custom rembg session.)

    # faster-whisper will download the CTranslate2 'medium' Whisper weights on
    # first run (~1.5GB). For CPU-only boxes, change device="cpu",
    # compute_type="int8" below.

    # sentence-transformers will download BAAI/bge-m3 (~2.2GB) on first run.
"""

from __future__ import annotations

import json
import logging
import os
from io import BytesIO
from pathlib import Path
from typing import Any, Dict, List, Optional

import httpx
from PIL import Image
from rembg import new_session, remove

logger = logging.getLogger("crafthaat.ai_engine")

# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------
LOCAL_MEDIA_DIR = Path(os.getenv("LOCAL_MEDIA_DIR", "/var/www/images"))
LOCAL_MEDIA_DIR.mkdir(parents=True, exist_ok=True)

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://localhost:11434/api/generate")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:3b-instruct")

REMBG_MODEL_NAME = os.getenv("REMBG_MODEL_NAME", "birefnet-general")  # RMBG-1.4-class model
WHISPER_MODEL_SIZE = os.getenv("WHISPER_MODEL_SIZE", "medium")
WHISPER_DEVICE = os.getenv("WHISPER_DEVICE", "cuda")  # fall back to "cpu" if no GPU
WHISPER_COMPUTE_TYPE = os.getenv("WHISPER_COMPUTE_TYPE", "float16")  # "int8" on CPU

EMBEDDING_MODEL_NAME = os.getenv("EMBEDDING_MODEL_NAME", "BAAI/bge-m3")

LLM_PROMPT_TEMPLATE = """You are a catalog assistant for Indian handicraft artisans selling on ONDC.
You are given a raw speech-to-text transcript (possibly in a regional Indian language,
possibly mixed with English) describing a handmade product. Produce a catalog entry.

Transcript:
\"\"\"{transcript}\"\"\"

Return ONLY a single valid JSON object (no markdown fences, no preamble, no commentary)
with EXACTLY these keys:
{{
  "title_en": "<short, appealing product title in English, max 8 words>",
  "title_hi": "<same title translated to natural Hindi (Devanagari script)>",
  "category": "<one of: Textiles, Pottery, Jewelry, Woodwork, Metalwork, Painting, Home Decor, Other>",
  "description_bullet_points": ["<3 to 5 short bullet points describing the product>"],
  "estimated_labor_hours": <number, estimated hours of skilled labor to make one unit>,
  "suggested_price": <number, suggested retail price in INR, integer>
}}
"""


class AIEngine:
    """Lazily-initialized, singleton-style wrapper around all local AI models.

    Model loading is expensive (GPU memory, disk I/O), so models are loaded
    once on first use and reused across requests. Instantiate ONE AIEngine
    per process (see main.py `app.state.ai_engine`).
    """

    def __init__(self) -> None:
        self._rembg_session = None
        self._whisper_model = None
        self._embedding_model = None
        self._http_client = httpx.AsyncClient(timeout=120.0)

    # ---------------------------------------------------------------- #
    # 1. Background removal
    # ---------------------------------------------------------------- #
    @property
    def rembg_session(self):
        if self._rembg_session is None:
            logger.info("Loading rembg session (%s)...", REMBG_MODEL_NAME)
            self._rembg_session = new_session(REMBG_MODEL_NAME)
        return self._rembg_session

    def remove_background(self, image_bytes: bytes) -> bytes:
        """Removes the background from a product photo and returns a clean PNG buffer."""
        input_image = Image.open(BytesIO(image_bytes)).convert("RGB")
        output_image: Image.Image = remove(input_image, session=self.rembg_session)

        buf = BytesIO()
        output_image.save(buf, format="PNG")
        return buf.getvalue()

    def save_cleaned_image(self, cleaned_png_bytes: bytes, filename_stem: str) -> str:
        """Persists the cleaned PNG to LOCAL_MEDIA_DIR and returns the saved path."""
        out_path = LOCAL_MEDIA_DIR / f"{filename_stem}_clean.png"
        out_path.write_bytes(cleaned_png_bytes)
        return str(out_path)

    # ---------------------------------------------------------------- #
    # 2. Speech-to-text
    # ---------------------------------------------------------------- #
    @property
    def whisper_model(self):
        if self._whisper_model is None:
            from faster_whisper import WhisperModel

            logger.info(
                "Loading faster-whisper model=%s device=%s compute_type=%s",
                WHISPER_MODEL_SIZE, WHISPER_DEVICE, WHISPER_COMPUTE_TYPE,
            )
            self._whisper_model = WhisperModel(
                WHISPER_MODEL_SIZE,
                device=WHISPER_DEVICE,
                compute_type=WHISPER_COMPUTE_TYPE,
            )
        return self._whisper_model

    def transcribe_audio(self, audio_path: str) -> Dict[str, str]:
        """Transcribes a regional-language voice clip. Returns {text, language}."""
        segments, info = self.whisper_model.transcribe(audio_path, beam_size=5)
        text = " ".join(segment.text.strip() for segment in segments).strip()
        return {"text": text, "language": info.language}

    # ---------------------------------------------------------------- #
    # 3. LLM catalog + pricing generation (Ollama)
    # ---------------------------------------------------------------- #
    async def generate_catalog(self, transcript: str) -> Dict[str, Any]:
        """Calls the local Ollama daemon and returns the parsed catalog JSON."""
        prompt = LLM_PROMPT_TEMPLATE.format(transcript=transcript)

        payload = {
            "model": OLLAMA_MODEL,
            "prompt": prompt,
            "stream": False,
            "format": "json",  # ask Ollama to enforce JSON-mode decoding
            "options": {"temperature": 0.3},
        }

        response = await self._http_client.post(OLLAMA_URL, json=payload)
        response.raise_for_status()
        raw = response.json()["response"]

        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            logger.warning("Ollama returned non-JSON; attempting to salvage: %s", raw[:200])
            data = _salvage_json(raw)

        return _validate_llm_output(data)

    # ---------------------------------------------------------------- #
    # 4. Vector embeddings (bge-m3)
    # ---------------------------------------------------------------- #
    @property
    def embedding_model(self):
        if self._embedding_model is None:
            from sentence_transformers import SentenceTransformer

            logger.info("Loading embedding model %s...", EMBEDDING_MODEL_NAME)
            self._embedding_model = SentenceTransformer(EMBEDDING_MODEL_NAME)
        return self._embedding_model

    def embed_text(self, text: str) -> List[float]:
        vector = self.embedding_model.encode(text, normalize_embeddings=True)
        return vector.tolist()

    # ---------------------------------------------------------------- #
    # 5. Pricing formula
    # ---------------------------------------------------------------- #
    @staticmethod
    def calculate_price(
        raw_material_cost: float,
        labor_hours: float,
        llm_suggested_price: float,
        hourly_labor_rate: float = 60.0,
        markup: float = 1.25,
    ) -> Dict[str, float]:
        """
        Cost = (Raw_Material_Cost + (Labor_Hours * hourly_labor_rate)) * markup
        Final suggested_price = max(Cost, LLM_Suggested_Price)
        """
        cost = (raw_material_cost + (labor_hours * hourly_labor_rate)) * markup
        final_price = max(cost, llm_suggested_price)
        return {"calculated_cost": round(cost, 2), "suggested_price": round(final_price, 2)}

    async def aclose(self) -> None:
        await self._http_client.aclose()


# ------------------------------------------------------------------------ #
# Helpers
# ------------------------------------------------------------------------ #
_REQUIRED_KEYS = {
    "title_en",
    "title_hi",
    "category",
    "description_bullet_points",
    "estimated_labor_hours",
    "suggested_price",
}


def _validate_llm_output(data: Dict[str, Any]) -> Dict[str, Any]:
    missing = _REQUIRED_KEYS - data.keys()
    if missing:
        raise ValueError(f"LLM output missing required keys: {missing}")

    data["estimated_labor_hours"] = float(data["estimated_labor_hours"])
    data["suggested_price"] = float(data["suggested_price"])
    if not isinstance(data["description_bullet_points"], list):
        data["description_bullet_points"] = [str(data["description_bullet_points"])]
    return data


def _salvage_json(raw: str) -> Dict[str, Any]:
    """Best-effort extraction of a JSON object from a noisy LLM response."""
    start = raw.find("{")
    end = raw.rfind("}")
    if start == -1 or end == -1:
        raise ValueError("Could not locate a JSON object in LLM response")
    return json.loads(raw[start : end + 1])
