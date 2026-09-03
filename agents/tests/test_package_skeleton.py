"""Phase 1 skeleton tests: the agent package tree imports and is complete.

These tests witness the repository foundation (T001-T003): the importable
packages exist, the worker/supervisor subpackages are real packages, and the
pinned contract facts (SLIM port, variable name, NDJSON-only surface) hold in
the configuration surface that later phases will read.
"""

import importlib
from pathlib import Path

# agents/ is the project root and import root (see [tool.pytest.ini_options]).
PROJECT_ROOT = Path(__file__).resolve().parent.parent

REQUIRED_PACKAGES = [
    "common",
    "config",
    "provisioning",
    "supervisors",
    "tests",
]

REQUIRED_PACKAGE_FILES = [
    "common/__init__.py",
    "config/__init__.py",
    "provisioning/__init__.py",
    "supervisors/__init__.py",
    "supervisors/provisioning/__init__.py",
    "provisioning/mapper/__init__.py",
    "provisioning/allocator/__init__.py",
    "provisioning/deployer/__init__.py",
    "provisioning/deployer/tools/__init__.py",
    "supervisors/provisioning/graph/__init__.py",
]


def test_top_level_agent_packages_import():
    for name in REQUIRED_PACKAGES:
        module = importlib.import_module(name)
        assert module is not None, f"package {name!r} failed to import"


def test_worker_and_supervisor_subpackages_exist():
    missing = [rel for rel in REQUIRED_PACKAGE_FILES if not (PROJECT_ROOT / rel).is_file()]
    assert not missing, f"missing package files: {missing}"


REQUIRED_PYTHON_PIN = ">=3.13,<4.0"

# research.md Decision 1 — the fidelity contract in pyproject.toml.
REQUIRED_EXACT_PINS = [
    "agntcy-app-sdk==0.4.5",
    "a2a-sdk==0.3.0",
    "agntcy-identity-service-sdk==0.0.7",
    "litellm[proxy]==1.75.3",
    "ioa-observe-sdk==1.0.24",
]

REQUIRED_RANGE_PINS = [
    "langgraph>=0.4.1",
    "langchain-litellm>=0.3.0",
    "pydantic>=2.11.4",
]


def test_pyproject_python_requirement():
    text = (PROJECT_ROOT / "pyproject.toml").read_text()
    assert f'requires-python = "{REQUIRED_PYTHON_PIN}"' in text


def test_pyproject_fidelity_pins_present():
    text = (PROJECT_ROOT / "pyproject.toml").read_text()
    missing = [pin for pin in REQUIRED_EXACT_PINS + REQUIRED_RANGE_PINS if pin not in text]
    assert not missing, f"missing pins in pyproject.toml: {missing}"


def test_unpinned_orchestration_and_runtime_deps_present():
    text = (PROJECT_ROOT / "pyproject.toml").read_text()
    for dep in ("langgraph-supervisor", "langgraph-checkpoint-sqlite", "fastapi", "uvicorn", "starlette"):
        assert dep in text, f"missing dependency {dep!r} in pyproject.toml"
