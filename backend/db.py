"""
CraftHaat — Database layer (PostgreSQL + pgvector)

Setup:
    # On the Postgres server, as superuser, once:
    #   CREATE EXTENSION IF NOT EXISTS vector;
    #
    # .env (or real env vars):
    #   DATABASE_URL=postgresql+asyncpg://crafthaat:crafthaat@localhost:5432/crafthaat
    #   MINIO_ENDPOINT=localhost:9000
    #   MINIO_ACCESS_KEY=minioadmin
    #   MINIO_SECRET_KEY=minioadmin
    #   MINIO_BUCKET=crafthaat-media
    #   OLLAMA_URL=http://localhost:11434/api/generate
    #   OLLAMA_MODEL=qwen2.5:3b-instruct
    #   LOCAL_MEDIA_DIR=/var/www/images
"""

import os
import uuid
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import (
    Column,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import JSONB, UUID
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

DATABASE_URL = os.getenv(
    "DATABASE_URL", "postgresql+asyncpg://crafthaat:crafthaat@localhost:5432/crafthaat"
)

engine = create_async_engine(DATABASE_URL, echo=False, pool_pre_ping=True)
AsyncSessionLocal = async_sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)


class Base(DeclarativeBase):
    pass


class Catalog(Base):
    """A single processed artisan listing."""

    __tablename__ = "catalogs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    artisan_id = Column(String, index=True, nullable=False)

    # Raw inputs
    raw_material_cost = Column(Float, nullable=False)
    original_image_path = Column(String, nullable=True)
    audio_path = Column(String, nullable=True)

    # AI pipeline outputs
    cleaned_image_path = Column(String, nullable=True)
    transcript = Column(Text, nullable=True)
    transcript_language = Column(String, nullable=True)

    title_en = Column(String, nullable=True)
    title_hi = Column(String, nullable=True)
    category = Column(String, nullable=True, index=True)
    description_bullet_points = Column(JSONB, nullable=True)  # list[str]
    estimated_labor_hours = Column(Float, nullable=True)
    llm_suggested_price = Column(Float, nullable=True)

    # Final pricing (see pricing formula in ai_engine.py)
    calculated_cost = Column(Float, nullable=True)
    suggested_price = Column(Float, nullable=True)

    # Vector embedding of "title_en + category" — bge-m3 = 1024 dims
    embedding = Column(Vector(1024), nullable=True)

    status = Column(String, default="pending_review")  # pending_review | approved | published
    ondc_payload = Column(JSONB, nullable=True)

    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)


async def init_db() -> None:
    """Create tables + vector extension if they don't exist. Call once on startup."""
    async with engine.begin() as conn:
        await conn.exec_driver_sql("CREATE EXTENSION IF NOT EXISTS vector;")
        await conn.run_sync(Base.metadata.create_all)


async def get_db():
    async with AsyncSessionLocal() as session:
        yield session
