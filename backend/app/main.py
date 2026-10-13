"""Builds the FastAPI app. Run with: uvicorn app.main:app"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import APIRouter, FastAPI

from app import __version__
from app.config import Settings, get_settings
from app.db import make_engine
from app.errors import install_error_handlers
from app.routers import (
    API_V1_PREFIX,
    auth,
    deck,
    files,
    health,
    listings,
    maps,
    me,
    renter_profile,
    swipes,
    uploads,
)
from app.services.email_sender import make_email_sender
from app.services.storage import ServerStorage, make_storage


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    logging.basicConfig(level=logging.INFO)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        yield
        app.state.engine.dispose()

    is_production = settings.env == "production"
    app = FastAPI(
        title="Sublette API",
        version=__version__,
        lifespan=lifespan,
        # Interactive docs are for developers; hide them from the public server.
        docs_url=None if is_production else "/docs",
        redoc_url=None,
        openapi_url=None if is_production else "/openapi.json",
    )
    app.state.settings = settings
    app.state.engine = make_engine(settings)
    app.state.email_sender = make_email_sender(settings)
    app.state.storage = make_storage(settings, app.state.engine)

    install_error_handlers(app)
    app.include_router(health.router)

    v1 = APIRouter(prefix=API_V1_PREFIX)
    v1.include_router(auth.router)
    v1.include_router(me.router)
    v1.include_router(uploads.router)
    v1.include_router(listings.router)
    v1.include_router(renter_profile.router)
    v1.include_router(deck.router)
    v1.include_router(swipes.router)
    v1.include_router(maps.router)
    app.include_router(v1)

    if isinstance(app.state.storage, ServerStorage):
        app.include_router(files.router)
    return app


app = create_app()
