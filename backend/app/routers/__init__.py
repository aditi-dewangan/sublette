"""HTTP routes.

`/health` sits at the root. Everything else is added to `api_v1`, which is
served under /v1. Every /v1 endpoint except sign-in requires a verified account.
"""

from fastapi import APIRouter

API_V1_PREFIX = "/v1"

api_v1 = APIRouter(prefix=API_V1_PREFIX)
