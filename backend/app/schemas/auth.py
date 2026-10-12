from pydantic import BaseModel, Field

from app.schemas.user import UserOut


class RequestCodeIn(BaseModel):
    email: str = Field(max_length=254)


class RequestCodeOut(BaseModel):
    # Seconds until the code stops working.
    expires_in: int
    # Seconds before another code can be requested for this email.
    resend_in: int


class VerifyIn(BaseModel):
    email: str = Field(max_length=254)
    code: str = Field(pattern=r"^\d{6}$")


class TokensOut(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    # Seconds until the access token expires.
    expires_in: int


class SessionOut(TokensOut):
    user: UserOut


class RefreshIn(BaseModel):
    refresh_token: str
