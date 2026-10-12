"""HTTP routes.

`/health` sits at the root. Everything else is served under /v1, and every
/v1 endpoint except the three under /v1/auth requires a verified account.
"""

API_V1_PREFIX = "/v1"
