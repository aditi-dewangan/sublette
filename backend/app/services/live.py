"""Live events for phones that have the app open: a WebSocket per phone.

Routes run on worker threads; each WebSocket runs on the server's event loop.
`publish` may be called from any thread: it hands the event to each of the
user's sockets on that socket's own loop.

The hub lives in this server process. One process serves everything today
(Render's free plan runs one). Running several would need a shared channel
such as PostgreSQL's LISTEN/NOTIFY; see docs/decisions.md.
"""

import asyncio
import threading
import uuid
from dataclasses import dataclass, field

# Close codes the app acts on. 4000 to 4999 are free for applications to use.
CLOSE_NOT_SIGNED_IN = 4401  # missing, invalid or expired token: refresh and reconnect
CLOSE_SUSPENDED = 4403  # the account can't be used: don't reconnect
# How many events wait for a slow phone before it is disconnected.
MAX_WAITING = 100


@dataclass(eq=False)
class Connection:
    user_id: uuid.UUID
    loop: asyncio.AbstractEventLoop
    events: asyncio.Queue = field(default_factory=lambda: asyncio.Queue(MAX_WAITING))
    # Set when the phone falls too far behind; the socket then closes.
    overflowed: asyncio.Event = field(default_factory=asyncio.Event)
    # Set when the account is suspended; the socket closes with 4403.
    suspended: asyncio.Event = field(default_factory=asyncio.Event)

    def deliver(self, event: dict) -> None:
        """Runs on the connection's own loop."""
        try:
            self.events.put_nowait(event)
        except asyncio.QueueFull:
            self.overflowed.set()


class LiveHub:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._connections: dict[uuid.UUID, set[Connection]] = {}

    def connect(self, user_id: uuid.UUID) -> Connection:
        """Call from the WebSocket's own coroutine."""
        connection = Connection(user_id=user_id, loop=asyncio.get_running_loop())
        with self._lock:
            self._connections.setdefault(user_id, set()).add(connection)
        return connection

    def disconnect(self, connection: Connection) -> None:
        with self._lock:
            mine = self._connections.get(connection.user_id)
            if mine is not None:
                mine.discard(connection)
                if not mine:
                    del self._connections[connection.user_id]

    def is_connected(self, user_id: uuid.UUID) -> bool:
        with self._lock:
            return bool(self._connections.get(user_id))

    def publish(self, user_id: uuid.UUID, event: dict) -> bool:
        """Send `event` to every phone `user_id` has connected. True if any."""
        with self._lock:
            targets = list(self._connections.get(user_id, ()))
        for connection in targets:
            try:
                connection.loop.call_soon_threadsafe(connection.deliver, event)
            except RuntimeError:
                # That loop has shut down; the socket is gone.
                self.disconnect(connection)
        return bool(targets)

    def suspend(self, user_id: uuid.UUID) -> None:
        """Close every socket of a suspended account. Any thread."""
        with self._lock:
            targets = list(self._connections.get(user_id, ()))
        for connection in targets:
            try:
                connection.loop.call_soon_threadsafe(connection.suspended.set)
            except RuntimeError:
                self.disconnect(connection)
