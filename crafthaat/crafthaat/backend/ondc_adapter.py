"""
CraftHaat — ONDC / Beckn Protocol Adapter
=============================================
Transforms an approved internal `Catalog` row into a Beckn Protocol
`on_search` catalog payload suitable for publishing to an ONDC Seller
Network Participant (SNP) gateway.

Reference: https://github.com/beckn/protocol-specifications

This module is intentionally dependency-free (pure Python) so it can be
unit-tested without spinning up the DB or AI models.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any, Dict


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def build_beckn_catalog_payload(
    catalog: Dict[str, Any],
    provider_id: str = "crafthaat-artisans",
    provider_name: str = "CraftHaat Artisan Collective",
    bpp_id: str = "crafthaat.bpp.ondc.example",
    bpp_uri: str = "https://bpp.crafthaat.example",
    domain: str = "ONDC:RET10",  # Handicrafts / home & decor retail domain
    currency: str = "INR",
    country: str = "IND",
    city_code: str = "std:080",  # example: Bengaluru STD code; override per artisan
) -> Dict[str, Any]:
    """Builds a Beckn `on_search` message envelope wrapping a single-item catalog.

    `catalog` is expected to be a dict with at least the keys produced by the
    /api/v1/process-catalog pipeline: id, title_en, title_hi, category,
    description_bullet_points, cleaned_image_path, suggested_price,
    artisan_id, estimated_labor_hours.
    """

    item_id = str(catalog["id"])
    transaction_id = str(uuid.uuid4())
    message_id = str(uuid.uuid4())
    timestamp = _iso_now()

    description = " | ".join(catalog.get("description_bullet_points") or [])
    price_value = f'{catalog.get("suggested_price", 0):.2f}'

    image_url = catalog.get("cleaned_image_path", "")

    payload: Dict[str, Any] = {
        "context": {
            "domain": domain,
            "country": country,
            "city": city_code,
            "action": "on_search",
            "core_version": "1.2.0",
            "bap_id": None,
            "bap_uri": None,
            "bpp_id": bpp_id,
            "bpp_uri": bpp_uri,
            "transaction_id": transaction_id,
            "message_id": message_id,
            "timestamp": timestamp,
            "ttl": "PT30S",
        },
        "message": {
            "catalog": {
                "bpp/descriptor": {
                    "name": provider_name,
                },
                "bpp/providers": [
                    {
                        "id": provider_id,
                        "descriptor": {
                            "name": provider_name,
                        },
                        "category_id": catalog.get("category", "Other"),
                        "items": [
                            {
                                "id": item_id,
                                "descriptor": {
                                    "name": catalog.get("title_en", ""),
                                    "short_desc": catalog.get("title_en", ""),
                                    "long_desc": description,
                                    "images": [image_url] if image_url else [],
                                    "additional_desc": {
                                        "hindi_title": catalog.get("title_hi", ""),
                                    },
                                },
                                "price": {
                                    "currency": currency,
                                    "value": price_value,
                                    "estimated_value": price_value,
                                },
                                "category_id": catalog.get("category", "Other"),
                                "fulfillment_id": "artisan-direct-ship",
                                "tags": [
                                    {
                                        "code": "origin",
                                        "list": [
                                            {"code": "artisan_id", "value": catalog.get("artisan_id", "")}
                                        ],
                                    },
                                    {
                                        "code": "production",
                                        "list": [
                                            {
                                                "code": "estimated_labor_hours",
                                                "value": str(catalog.get("estimated_labor_hours", "")),
                                            }
                                        ],
                                    },
                                ],
                            }
                        ],
                    }
                ],
            }
        },
    }

    return payload
