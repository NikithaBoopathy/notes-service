"""
Minimal but real FastAPI service.

Why a "notes" resource instead of a bare hello-world: a hello-world endpoint
doesn't actually exercise Postgres or Redis, which kind of defeats the point
of an infra exercise. Notes CRUD gives us a real write path (Postgres) and a
real cache path (Redis) to reason about when something breaks in prod.
"""
import os
import time
import logging
from contextlib import asynccontextmanager
from typing import Optional

import redis
from fastapi import FastAPI, HTTPException, Depends
from pydantic import BaseModel, Field
from sqlalchemy import create_engine, Column, Integer, String, DateTime, text
from sqlalchemy.orm import sessionmaker, declarative_base, Session
from sqlalchemy.exc import OperationalError
import datetime

# ---------------------------------------------------------------------------
# Logging - JSON-ish single line logs so they're easy to grep/ship to a
# log aggregator later. Going with stdout only; container runtime / docker
# logging driver handles persistence. See docs/logging.md for the reasoning.
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","module":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("app")

# ---------------------------------------------------------------------------
# Config (env-driven, see .env.example)
# ---------------------------------------------------------------------------
DATABASE_URL = os.getenv("DATABASE_URL", "postgresql://app:app@db:5432/appdb")
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379/0")
APP_ENV = os.getenv("APP_ENV", "development")

# ---------------------------------------------------------------------------
# DB setup. pool_pre_ping avoids the classic "stale connection after DB
# restart" error that shows up in production after a few days of idling.
# ---------------------------------------------------------------------------
engine = create_engine(DATABASE_URL, pool_pre_ping=True, pool_size=5, max_overflow=10)
SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
Base = declarative_base()


class Note(Base):
    __tablename__ = "notes"
    id = Column(Integer, primary_key=True, index=True)
    title = Column(String(200), nullable=False)
    body = Column(String(4000), nullable=True)
    created_at = Column(DateTime, default=datetime.datetime.utcnow)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# Redis client - decode_responses so we deal in str, not bytes
redis_client = redis.from_url(REDIS_URL, decode_responses=True, socket_connect_timeout=2)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Retry loop on startup - in docker-compose, the app container can start
    # before postgres has finished initializing, even with depends_on,
    # because depends_on only waits for the container to start, not for
    # postgres to be ready to accept connections. healthcheck dependency
    # in compose mitigates most of this but we still retry defensively.
    retries = 10
    for attempt in range(1, retries + 1):
        try:
            Base.metadata.create_all(bind=engine)
            log.info(f"DB ready after {attempt} attempt(s)")
            break
        except OperationalError as e:
            log.warning(f"DB not ready (attempt {attempt}/{retries}): {e}")
            time.sleep(2)
    else:
        log.error("DB never became ready, starting anyway - /health will report it")
    yield
    log.info("Shutting down")


app = FastAPI(title="notes-service", version="1.0.0", lifespan=lifespan)


class NoteIn(BaseModel):
    title: str = Field(..., max_length=200)
    body: Optional[str] = Field(None, max_length=4000)


class NoteOut(NoteIn):
    id: int

    class Config:
        from_attributes = True


# ---------------------------------------------------------------------------
# Health check - deliberately checks real dependencies rather than just
# returning 200. A health check that always says "ok" is worse than no
# health check, because it gives operators false confidence.
# ---------------------------------------------------------------------------
@app.get("/health")
def health(db: Session = Depends(get_db)):
    status = {"status": "ok", "checks": {}}
    try:
        db.execute(text("SELECT 1"))
        status["checks"]["postgres"] = "ok"
    except Exception as e:
        status["checks"]["postgres"] = f"error: {e}"
        status["status"] = "degraded"

    try:
        redis_client.ping()
        status["checks"]["redis"] = "ok"
    except Exception as e:
        status["checks"]["redis"] = f"error: {e}"
        status["status"] = "degraded"

    if status["status"] != "ok":
        raise HTTPException(status_code=503, detail=status)
    return status


@app.get("/")
def root():
    return {"service": "notes-service", "env": APP_ENV}


@app.post("/notes", response_model=NoteOut, status_code=201)
def create_note(note: NoteIn, db: Session = Depends(get_db)):
    db_note = Note(title=note.title, body=note.body)
    db.add(db_note)
    db.commit()
    db.refresh(db_note)
    redis_client.delete("notes:list")  # invalidate list cache
    log.info(f"created note id={db_note.id}")
    return db_note


@app.get("/notes/{note_id}", response_model=NoteOut)
def read_note(note_id: int, db: Session = Depends(get_db)):
    cache_key = f"notes:{note_id}"
    cached = redis_client.get(cache_key)
    if cached:
        log.info(f"cache hit note id={note_id}")
        import json
        return json.loads(cached)

    note = db.query(Note).filter(Note.id == note_id).first()
    if not note:
        raise HTTPException(status_code=404, detail="note not found")

    out = NoteOut.model_validate(note).model_dump()
    import json
    redis_client.setex(cache_key, 60, json.dumps(out))  # 60s cache
    return out


@app.delete("/notes/{note_id}", status_code=204)
def delete_note(note_id: int, db: Session = Depends(get_db)):
    note = db.query(Note).filter(Note.id == note_id).first()
    if not note:
        raise HTTPException(status_code=404, detail="note not found")
    db.delete(note)
    db.commit()
    redis_client.delete(f"notes:{note_id}")
    redis_client.delete("notes:list")
    return None
