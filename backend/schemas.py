"""CraftHaat — Pydantic schemas for API request/response bodies."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict


class CatalogOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    artisan_id: str
    raw_material_cost: float

    cleaned_image_path: Optional[str] = None
    transcript: Optional[str] = None
    transcript_language: Optional[str] = None

    title_en: Optional[str] = None
    title_hi: Optional[str] = None
    category: Optional[str] = None
    description_bullet_points: Optional[List[str]] = None
    estimated_labor_hours: Optional[float] = None
    llm_suggested_price: Optional[float] = None

    calculated_cost: Optional[float] = None
    suggested_price: Optional[float] = None

    status: str
    created_at: datetime


class ProcessCatalogResponse(BaseModel):
    catalog: CatalogOut
    message: str = "Catalog processed successfully"


class OndcPublishRequest(BaseModel):
    catalog_id: uuid.UUID
    provider_id: str = "crafthaat-artisans"
    provider_name: str = "CraftHaat Artisan Collective"


class OndcPublishResponse(BaseModel):
    catalog_id: uuid.UUID
    beckn_payload: dict
