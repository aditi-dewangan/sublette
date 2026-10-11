"""Builds the FastAPI app. Run with: uvicorn app.main:app"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app import __version__
from app.config import Settings, get_settings
from app.db import make_engine
from app.errors import install_error_handlers
from app.routers import api_v1, health


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

    install_error_handlers(app)
    app.include_router(health.router)
    app.include_router(api_v1)
    return app


app = create_app()
