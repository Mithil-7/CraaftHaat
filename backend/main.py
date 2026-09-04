"""
CraftHaat — FastAPI backend entry point
============================================

Setup:
    pip install -r requirements.txt

    # Postgres (with pgvector extension available) + MinIO must be running.
    # Easiest local setup via docker:
    docker run -d --name crafthaat-pg -e POSTGRES_USER=crafthaat \\
        -e POSTGRES_PASSWORD=crafthaat -e POSTGRES_DB=crafthaat \\
        -p 5432:5432 ankane/pgvector

    docker run -d --name crafthaat-minio -p 9000:9000 -p 9001:9001 \\
        -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \\
        minio/minio server /data --console-address ":9001"

    # Ollama (local LLM) must be running with the model pulled:
    ollama pull qwen2.5:3b-instruct
    ollama serve

    # Run the API:
    uvicorn main:app --host 0.0.0.0 --port 8000 --reload
"""

from __future__ import annotations

import logging
import os
import shutil
import tempfile
import uuid
from pathlib import Path
from typing import List

from fastapi import Depends, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from minio import Minio
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from ai_engine import AIEngine
from db import Catalog, get_db, init_db
from ondc_adapter import build_beckn_catalog_payload
from schemas import (
    CatalogOut,
    OndcPublishRequest,
    OndcPublishResponse,
    ProcessCatalogResponse,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("crafthaat.main")

# --------------------------------------------------------------------------
# MinIO (object storage) config
# --------------------------------------------------------------------------
MINIO_ENDPOINT = os.getenv("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY = os.getenv("MINIO_ACCESS_KEY", "minioadmin")
MINIO_SECRET_KEY = os.getenv("MINIO_SECRET_KEY", "minioadmin")
MINIO_BUCKET = os.getenv("MINIO_BUCKET", "crafthaat-media")
MINIO_SECURE = os.getenv("MINIO_SECURE", "false").lower() == "true"

minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=MINIO_SECURE,
)


def ensure_bucket() -> None:
    if not minio_client.bucket_exists(MINIO_BUCKET):
        minio_client.make_bucket(MINIO_BUCKET)
        logger.info("Created MinIO bucket '%s'", MINIO_BUCKET)


# --------------------------------------------------------------------------
# FastAPI app
# --------------------------------------------------------------------------
app = FastAPI(
    title="CraftHaat Backend",
    description="Self-hosted AI backend for marginalized artisans — catalog generation, "
    "pricing, and ONDC/Beckn publishing.",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # tighten to the mobile app's origin(s) in production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.on_event("startup")
async def on_startup() -> None:
    await init_db()
    ensure_bucket()
    app.state.ai_engine = AIEngine()
    logger.info("CraftHaat backend started.")


@app.on_event("shutdown")
async def on_shutdown() -> None:
    await app.state.ai_engine.aclose()


def get_ai_engine() -> AIEngine:
    return app.state.ai_engine


# --------------------------------------------------------------------------
# 1. POST /api/v1/process-catalog
# --------------------------------------------------------------------------
@app.post("/api/v1/process-catalog", response_model=ProcessCatalogResponse)
async def process_catalog(
    image: UploadFile = File(...),
    audio: UploadFile = File(...),
    raw_material_cost: float = Form(...),
    artisan_id: str = Form(...),
    db: AsyncSession = Depends(get_db),
    ai_engine: AIEngine = Depends(get_ai_engine),
):
    """
    Runs the full pipeline on a captured (image, audio) pair:
      1. rembg background removal on the image
      2. faster-whisper transcription of the voice note
      3. Ollama (qwen2.5:3b-instruct) catalog + pricing generation
      4. bge-m3 embedding of the generated title/category
      5. Deterministic pricing formula, final price = max(cost, LLM price)
    Persists the result to Postgres and the media files to MinIO + local disk.
    """
    request_id = uuid.uuid4()

    # --- read uploads into memory / temp files -----------------------
    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(400, "Empty image upload")

    audio_bytes = await audio.read()
    if not audio_bytes:
        raise HTTPException(400, "Empty audio upload")

    # Persist raw uploads to MinIO for audit/reprocessing
    image_ext = Path(image.filename or "capture.jpg").suffix or ".jpg"
    audio_ext = Path(audio.filename or "voice.m4a").suffix or ".m4a"
    raw_image_object = f"{artisan_id}/{request_id}/original{image_ext}"
    raw_audio_object = f"{artisan_id}/{request_id}/voice{audio_ext}"

    _put_bytes_to_minio(raw_image_object, image_bytes, image.content_type)
    _put_bytes_to_minio(raw_audio_object, audio_bytes, audio.content_type)

    # faster-whisper needs a real file path
    with tempfile.NamedTemporaryFile(suffix=audio_ext, delete=False) as tmp_audio:
        tmp_audio.write(audio_bytes)
        tmp_audio_path = tmp_audio.name

    try:
        # --- 1. Background removal ------------------------------------
        cleaned_png = ai_engine.remove_background(image_bytes)
        cleaned_path = ai_engine.save_cleaned_image(cleaned_png, str(request_id))
        _put_bytes_to_minio(f"{artisan_id}/{request_id}/clean.png", cleaned_png, "image/png")

        # --- 2. Speech-to-text ------------------------------------------
        transcription = ai_engine.transcribe_audio(tmp_audio_path)
        transcript_text = transcription["text"]
        if not transcript_text:
            raise HTTPException(422, "Could not transcribe any speech from the audio")

        # --- 3. LLM catalog + pricing generation -------------------------
        llm_result = await ai_engine.generate_catalog(transcript_text)

        # --- 5. Deterministic pricing formula -----------------------------
        pricing = ai_engine.calculate_price(
            raw_material_cost=raw_material_cost,
            labor_hours=llm_result["estimated_labor_hours"],
            llm_suggested_price=llm_result["suggested_price"],
        )

        # --- 4. Embedding for pgvector -------------------------------------
        embedding_input = f"{llm_result['title_en']} {llm_result['category']}"
        embedding = ai_engine.embed_text(embedding_input)

        # --- persist -------------------------------------------------------
        catalog = Catalog(
            id=request_id,
            artisan_id=artisan_id,
            raw_material_cost=raw_material_cost,
            original_image_path=raw_image_object,
            audio_path=raw_audio_object,
            cleaned_image_path=cleaned_path,
            transcript=transcript_text,
            transcript_language=transcription["language"],
            title_en=llm_result["title_en"],
            title_hi=llm_result["title_hi"],
            category=llm_result["category"],
            description_bullet_points=llm_result["description_bullet_points"],
            estimated_labor_hours=llm_result["estimated_labor_hours"],
            llm_suggested_price=llm_result["suggested_price"],
            calculated_cost=pricing["calculated_cost"],
            suggested_price=pricing["suggested_price"],
            embedding=embedding,
            status="pending_review",
        )
        db.add(catalog)
        await db.commit()
        await db.refresh(catalog)

        return ProcessCatalogResponse(catalog=CatalogOut.model_validate(catalog))

    finally:
        Path(tmp_audio_path).unlink(missing_ok=True)


def _put_bytes_to_minio(object_name: str, data: bytes, content_type: str | None) -> None:
    from io import BytesIO

    minio_client.put_object(
        MINIO_BUCKET,
        object_name,
        data=BytesIO(data),
        length=len(data),
        content_type=content_type or "application/octet-stream",
    )


# --------------------------------------------------------------------------
# 2. GET /api/v1/catalogs/{artisan_id}
# --------------------------------------------------------------------------
@app.get("/api/v1/catalogs/{artisan_id}", response_model=List[CatalogOut])
async def get_catalogs(artisan_id: str, db: AsyncSession = Depends(get_db)):
    """Retrieves all processed catalog listings for a given artisan."""
    result = await db.execute(
        select(Catalog).where(Catalog.artisan_id == artisan_id).order_by(Catalog.created_at.desc())
    )
    catalogs = result.scalars().all()
    return [CatalogOut.model_validate(c) for c in catalogs]


# --------------------------------------------------------------------------
# 3. POST /api/v1/ondc/publish
# --------------------------------------------------------------------------
@app.post("/api/v1/ondc/publish", response_model=OndcPublishResponse)
async def publish_to_ondc(request: OndcPublishRequest, db: AsyncSession = Depends(get_db)):
    """Converts an approved catalog into a Beckn Protocol on_search payload
    and marks it as published. (Actual network call to the ONDC gateway is
    left as an integration point — see `# TODO: POST to BPP gateway` below.)
    """
    catalog = await db.get(Catalog, request.catalog_id)
    if catalog is None:
        raise HTTPException(404, "Catalog not found")

    if catalog.status not in ("approved", "pending_review"):
        raise HTTPException(400, f"Catalog is in status '{catalog.status}', cannot publish")

    catalog_dict = {
        "id": catalog.id,
        "artisan_id": catalog.artisan_id,
        "title_en": catalog.title_en,
        "title_hi": catalog.title_hi,
        "category": catalog.category,
        "description_bullet_points": catalog.description_bullet_points,
        "cleaned_image_path": catalog.cleaned_image_path,
        "suggested_price": catalog.suggested_price,
        "estimated_labor_hours": catalog.estimated_labor_hours,
    }

    beckn_payload = build_beckn_catalog_payload(
        catalog_dict,
        provider_id=request.provider_id,
        provider_name=request.provider_name,
    )

    catalog.status = "published"
    catalog.ondc_payload = beckn_payload
    await db.commit()

    # TODO: POST beckn_payload to your ONDC Seller Network Participant (BPP)
    # gateway here, e.g.:
    #   async with httpx.AsyncClient() as client:
    #       await client.post(f"{BPP_URI}/on_search", json=beckn_payload)

    return OndcPublishResponse(catalog_id=catalog.id, beckn_payload=beckn_payload)


@app.get("/health")
async def health():
    return {"status": "ok"}
