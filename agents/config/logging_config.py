"""logging_config.py — ported from the subject's ``config/logging_config.py``,
extended with the credential-redaction wiring (T064 / FR-031 / SC-016).

Phase 3 (T108): the redaction patterns are no longer defined here — the
single source of truth is ``common/redaction.py`` (T106). The
:class:`RedactingFilter` below applies those patterns to every log record
through this module, so the log path, the prompt/response path
(:func:`common.redaction.redact`), and the audit path
(``common/audit.py``) scrub with exactly the same rules and cannot drift
apart.
"""

from __future__ import annotations

import logging

from common.redaction import CREDENTIAL_PATTERNS
from config.config import LOGGING_LEVEL

# ---------------------------------------------------------------------------
# Credential redaction (FR-031: no credential appears in logs or traces;
# SC-016 reconciles that). The subject's setup_logging() is kept intact
# (same level, format, noisy-library dampening); on top of it a
# RedactingFilter is wired onto the root handlers so every formatted record
# is scrubbed before it leaves the process.
#
# T108: the patterns come from common/redaction.py — the same list applied
# to prompts and model responses (T106/T107). Kept as a module-level name
# for backward compatibility with Phase 2 references.
# ---------------------------------------------------------------------------
_REDACTION_PATTERNS: list = CREDENTIAL_PATTERNS


class RedactingFilter(logging.Filter):
    """Scrub credential-shaped values from every formatted record.

    Applied at the handler level via :func:`setup_logging`, so it covers the
    tier's own loggers and the noisy third-party ones alike (a third-party
    library logging an Authorization header cannot leak it).
    """

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
        except Exception:  # noqa: BLE001 - a broken record must not break logging
            return True
        redacted = message
        for pattern, replacement in _REDACTION_PATTERNS:
            redacted = pattern.sub(replacement, redacted)
        if redacted != message:
            record.msg = redacted
            record.args = ()
        return True


def setup_logging() -> None:
    logging.basicConfig(
        level=LOGGING_LEVEL,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        force=True,
    )

    # Wire the redaction filter onto every existing and future root handler
    # (T064/T108): FR-031/SC-016 hold for whatever a dependency logs.
    for handler in logging.getLogger().handlers:
        if not any(isinstance(f, RedactingFilter) for f in handler.filters):
            handler.addFilter(RedactingFilter())

    # Set specific logging levels for noisy libraries
    logging.basicConfig(level=logging.INFO)  # default
    logging.getLogger("openai").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("httpx").setLevel(logging.WARNING)
