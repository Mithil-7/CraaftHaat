# CraftHaat

Offline-first mobile app + self-hosted AI backend that lets marginalized
artisans list handmade products on ONDC using just a voice note and a
photo — no typing required.

An artisan holds a button, describes their product out loud in their own
language, and takes a photo. Everything else — background removal,
transcription, bilingual catalog copy, fair pricing, and ONDC/Beckn
publishing — happens automatically, and captures queue locally until a
network connection is available.

---

## Repository structure

```
crafthaat/
├── README.md
├── .gitignore
│
├── backend/                     # FastAPI + self-hosted AI pipeline
│   ├── main.py                  # App entry point, routes, CORS, MinIO wiring
│   ├── ai_engine.py             # rembg + faster-whisper + Ollama + bge-m3 pipeline
│   ├── ondc_adapter.py          # Beckn Protocol / ONDC payload transformer
│   ├── db.py                    # SQLAlchemy async engine + Catalog model (pgvector)
│   ├── schemas.py                # Pydantic request/response models
│   ├── requirements.txt
│   └── .env.example              # Copy to .env and fill in for local dev
│
└── mobile/                       # Flutter app (offline-first, audio-first UI)
    ├── pubspec.yaml
    └── lib/
        ├── main.dart              # App entry point, Hive init, routing
        ├── bloc/
        │   └── capture_cubit.dart # State for hold-to-record + camera capture
        ├── models/
        │   └── pending_item.dart  # Hive model for the local draft queue
        ├── repositories/
        │   └── .gitkeep           # Reserved: future repository-pattern data
        │                          # access layer (e.g. wrapping API + Hive
        │                          # reads behind a single interface). Empty
        │                          # for now — Git can't track empty folders,
        │                          # so this placeholder keeps the structure
        │                          # intact until real files land here.
        ├── screens/
        │   ├── capture_screen.dart          # Screen 1: record + shutter
        │   ├── draft_queue_screen.dart      # Screen 2: offline queue status
        │   └── catalog_preview_screen.dart  # Screen 3: preview + approve
        └── services/
            └── offline_queue.dart # Hive persistence + connectivity-aware sync
```

> **Note on empty folders:** `mobile/lib/repositories/` currently has no
> Dart files in it — it's scaffolded for a future data-access layer that
> sits between the BLoC/Cubit layer and `offline_queue.dart` /
> `http` calls. Since Git only tracks files (not directories), it ships
> with a `.gitkeep` placeholder so `git clone` reproduces this exact
> folder layout. Delete `.gitkeep` once you add real files there.

---

## Architecture

```
mobile/ (Flutter)                      backend/ (FastAPI, Python 3.11+)
┌───────────────────────┐              ┌──────────────────────────────┐
│ Screen 1: Capture      │  multipart   │ POST /api/v1/process-catalog │
│  - hold-to-record 🎙️   │─────────────▶│  -> rembg (bg removal)       │
│  - camera shutter 📸   │  (on WiFi/   │  -> faster-whisper (STT)     │
│                        │   mobile)    │  -> Ollama qwen2.5 (catalog) │
│ Screen 2: Draft Queue  │              │  -> bge-m3 (embeddings)      │
│  - Hive local box      │              │  -> Postgres + pgvector      │
│  - connectivity_plus   │              │                              │
│    triggers sync       │              │ GET /api/v1/catalogs/{id}    │
│                        │◀────────────▶│                              │
│ Screen 3: Catalog      │              │ POST /api/v1/ondc/publish    │
│  Preview + Approve     │              │  -> ondc_adapter.py (Beckn)  │
│  & Push to ONDC        │              │                              │
└───────────────────────┘              └──────────────────────────────┘
                                                     │
                                        Postgres+pgvector · MinIO · Ollama
```

---

## Backend setup

1. **Prerequisites:** Python 3.11+, Docker, [Ollama](https://ollama.com).

2. **Start Postgres (pgvector) + MinIO:**
   ```bash
   docker run -d --name crafthaat-pg -e POSTGRES_USER=crafthaat \
     -e POSTGRES_PASSWORD=crafthaat -e POSTGRES_DB=crafthaat \
     -p 5432:5432 ankane/pgvector

   docker run -d --name crafthaat-minio -p 9000:9000 -p 9001:9001 \
     -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin \
     minio/minio server /data --console-address ":9001"
   ```

3. **Pull and run the local LLM:**
   ```bash
   ollama pull qwen2.5:3b-instruct
   ollama serve
   ```

4. **Set up the Python environment:**
   ```bash
   cd backend
   python3.11 -m venv venv && source venv/bin/activate
   pip install -r requirements.txt
   cp .env.example .env   # edit if you changed ports/credentials
   sudo mkdir -p /var/www/images && sudo chown $USER /var/www/images
   ```

   No GPU? In `.env`, set `WHISPER_DEVICE=cpu` and `WHISPER_COMPUTE_TYPE=int8`.

5. **Run the API:**
   ```bash
   uvicorn main:app --host 0.0.0.0 --port 8000 --reload
   ```
   First run downloads model weights (~4–5GB total: rembg, faster-whisper,
   bge-m3). Check `http://localhost:8000/health`.

---

## Mobile setup

1. **Prerequisites:** Flutter SDK 3.3+, an emulator or device.

2. **Get dependencies:**
   ```bash
   cd mobile
   flutter pub get
   ```

3. **Point the app at your backend.** Defaults to `http://10.0.2.2:8000`
   (Android emulator's alias for the host machine):
   ```bash
   flutter run --dart-define=CRAFTHAAT_API_BASE_URL=http://192.168.1.X:8000
   ```

4. **Grant camera and microphone permissions** when prompted.

5. **Run it:**
   ```bash
   flutter run
   ```

---

## Smoke test

1. Hold the green mic button, describe a product, take a photo, enter a
   material cost, tap **Save** — this works even fully offline.
2. Turn Wi-Fi/data back on — the Draft Queue screen moves the item from
   *Queued* → *Uploading* → *Uploaded*.
3. Tap the uploaded item to view the AI-generated bilingual catalog and
   try **Approve & Push to ONDC**.

---

## Known gaps before production use

- `main.dart` uses a hardcoded `demoArtisanId` — wire up real auth.
- `cleaned_image_path` returned by the backend is a local filesystem path,
  not a public URL. Either mount it as static files
  (`app.mount("/media", StaticFiles(directory="/var/www/images"))` in
  `main.py`) or serve cleaned images from MinIO via presigned URLs.
- `POST /api/v1/ondc/publish` builds a valid Beckn payload but does not
  yet POST it to a live ONDC Seller Network Participant gateway — see the
  `# TODO: POST to BPP gateway` marker in `main.py`.

---

## License

Add your license of choice here (MIT/Apache-2.0 recommended for an
open, socially-oriented tool like this).
