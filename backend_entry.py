#!/usr/bin/env python3
"""PyInstaller entry point that preserves backend package imports."""

print("PROGRESS 0.005 Packaged runtime started", flush=True)

import sys

if "--group-stats" in sys.argv:
    sys.argv.remove("--group-stats")
    from backend.group_stats import main as group_stats_main
    if __name__ == "__main__":
        group_stats_main()
elif "--preprocess" in sys.argv:
    sys.argv.remove("--preprocess")
    from backend.preprocess import main as preprocess_main
    if __name__ == "__main__":
        preprocess_main()
else:
    from backend.cli import main

    if __name__ == "__main__":
        main()

