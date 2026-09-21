"""Configure the packaged Python runtime before importing third-party modules."""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path


def configure_runtime() -> None:
    backend_dir = Path(__file__).resolve().parent
    vendor_dir = backend_dir / "vendor"
    if vendor_dir.exists():
        vendor_path = str(vendor_dir)
        # Keep the bundled runtime deterministic when frozen.
        if getattr(sys, "frozen", False):
            sys.path[:] = [
                path
                for path in sys.path
                if "site-packages" not in path or Path(path).resolve() == vendor_dir.resolve()
            ]
        if vendor_path in sys.path:
            sys.path.remove(vendor_path)
        sys.path.insert(0, vendor_path)

    cache_root = Path(tempfile.gettempdir()) / "scoring_nidra_backend_cache"
    cache_root.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("NUMBA_CACHE_DIR", str(cache_root / "numba"))
    os.environ.setdefault("MPLCONFIGDIR", str(cache_root / "matplotlib"))
    os.environ.setdefault("_MNE_FAKE_HOME_DIR", str(cache_root / "mne"))
    os.environ.setdefault("OUTDATED_IGNORE", "1")

    for name in (
        "OMP_NUM_THREADS",
        "MKL_NUM_THREADS",
        "OPENBLAS_NUM_THREADS",
        "VECLIB_MAXIMUM_THREADS",
        "NUMEXPR_NUM_THREADS",
    ):
        os.environ.setdefault(name, "1")

    # Prevent transformers runtime version-check crashes caused by vendored huggingface_hub
    import types
    if "transformers.dependency_versions_check" not in sys.modules:
        m = types.ModuleType("transformers.dependency_versions_check")
        m.dep_version_check = lambda *args, **kwargs: None
        m.require_version = lambda *args, **kwargs: None
        m.require_version_core = lambda *args, **kwargs: None
        sys.modules["transformers.dependency_versions_check"] = m

    # Prevent torchvision ABI conflicts with torch from breaking transformers model loading
    try:
        import torchvision  # noqa: F401
    except Exception:
        sys.modules["torchvision"] = None
        sys.modules["torchvision.transforms"] = None

    # ── numpy / scipy compatibility shims ─────────────────────────────────────
    # Must run before any algorithm code is imported so that packages
    # built against older numpy/scipy APIs work without modification.
    try:
        import numpy as np
        if not hasattr(np, "trapz"):
            np.trapz = np.trapezoid  # type: ignore[attr-defined]
        if not hasattr(np, "in1d"):
            np.in1d = np.isin  # type: ignore[attr-defined]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", (FutureWarning, UserWarning, DeprecationWarning))
            for _alias in ("bool", "int", "float", "complex", "object", "str"):
                if not hasattr(np, _alias):
                    _bi = __builtins__ if isinstance(__builtins__, dict) else vars(__builtins__)
                    setattr(np, _alias, _bi.get(_alias))
    except Exception:
        pass

    try:
        import scipy.integrate as _si
        if not hasattr(_si, "simps"):
            _si.simps = _si.simpson  # type: ignore[attr-defined]
    except Exception:
        pass

    # ── ccstools path discovery ───────────────────────────────────────────────
    # Finds the ccstools submodule in both frozen (PyInstaller) and dev contexts.
    backend_dir = Path(__file__).resolve().parent
    _ccstools_candidates = [
        # PyInstaller bundle: ccstools data is unpacked into _MEIPASS
        Path(getattr(sys, "_MEIPASS", "")),
        # Dev: submodule at repo-root/vendor/ccstools
        backend_dir.parent / "vendor" / "ccstools",
        backend_dir / "vendor" / "ccstools",
    ]
    for _cc in _ccstools_candidates:
        if _cc and (_cc / "ccstools" / "__init__.py").exists():
            _cc_str = str(_cc.resolve())
            if _cc_str not in sys.path:
                sys.path.insert(0, _cc_str)
            break
