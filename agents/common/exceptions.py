"""Transport-layer error types for the intent tier.

The subject declared this module misspelled and never wired it in
(``agents/exeptions.py`` — REVERSE.md Finding 5). This is the corrected,
finally-wired module: ``AuthError`` is the type raised for
transport-authentication failures under FR-024 (an unauthenticated worker
registration against the SLIM gateway must be refused, and the refusal
surfaces to the operator as this error type — research.md Decision 6,
contracts/a2a-transport.md).
"""

from __future__ import annotations


class AuthError(Exception):
    """Raised when the message transport rejects the worker's credentials.

    Per FR-024 the SLIM gateway runs TLS with client-certificate
    verification and a generated PASSWORD; a registration or session attempt
    that is refused for authentication reasons raises this error. It must
    never be swallowed into a generic stage failure: the operator is told the
    transport is unauthenticated, and the stage fails naming the transport.
    """
