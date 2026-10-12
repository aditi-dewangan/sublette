"""Distances and the public offset that hides a listing's exact address."""

import math
import random
import secrets

EARTH_RADIUS_M = 6_371_000

# A listing's public point sits this far from the real one, in a random
# direction picked once. Far enough to hide the building; close enough that
# distances shown to renters stay honest.
OFFSET_MIN_M = 120
OFFSET_MAX_M = 180


def distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Great-circle distance in meters."""
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    d_phi = phi2 - phi1
    d_lambda = math.radians(lng2 - lng1)
    a = math.sin(d_phi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(d_lambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def offset_point(lat: float, lng: float, rng: random.Random | None = None) -> tuple[float, float]:
    """A point 120 to 180 meters from (lat, lng) in a random direction."""
    rng = rng or secrets.SystemRandom()
    distance = rng.uniform(OFFSET_MIN_M, OFFSET_MAX_M)
    bearing = rng.uniform(0, 2 * math.pi)
    angular = distance / EARTH_RADIUS_M
    phi1, lambda1 = math.radians(lat), math.radians(lng)
    phi2 = math.asin(
        math.sin(phi1) * math.cos(angular) + math.cos(phi1) * math.sin(angular) * math.cos(bearing)
    )
    lambda2 = lambda1 + math.atan2(
        math.sin(bearing) * math.sin(angular) * math.cos(phi1),
        math.cos(angular) - math.sin(phi1) * math.sin(phi2),
    )
    longitude = (math.degrees(lambda2) + 540) % 360 - 180
    return math.degrees(phi2), longitude
