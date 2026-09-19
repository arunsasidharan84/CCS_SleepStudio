#!/usr/bin/env python3
"""Tkinter UI for automated sleep scoring."""

from __future__ import annotations

import os
import sys

# Set CPU thread limits for backend numeric and ML libraries to avoid OpenMP deadlocks on macOS
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["MKL_NUM_THREADS"] = "1"
os.environ["OPENBLAS_NUM_THREADS"] = "1"
os.environ["VECLIB_MAXIMUM_THREADS"] = "1"
os.environ["NUMEXPR_NUM_THREADS"] = "1"

import warnings
warnings.filterwarnings("ignore", message="DataFrame is highly fragmented")
warnings.filterwarnings("ignore", message="Using padding='same'")
try:
    import pandas as pd
    warnings.filterwarnings("ignore", category=pd.errors.PerformanceWarning)
except Exception:
    pass

import subprocess
from pathlib import Path

def bootstrap():
    # If running inside a virtual environment or conda env, skip bootstrapping
    if sys.prefix != sys.base_prefix:
        return
        
    app_dir = Path(__file__).resolve().parent
    venv_dir = app_dir / ".venv"
    
    exe_name = "python.exe" if os.name == "nt" else "python"
    bin_dir = "Scripts" if os.name == "nt" else "bin"
    python_exe = venv_dir / bin_dir / exe_name
    
    if not python_exe.exists():
        print("Virtual environment not found. Setting up .venv...", flush=True)
        try:
            import tkinter as tk
            from tkinter import messagebox
            root = tk.Tk()
            root.withdraw()
            confirm = messagebox.askyesno(
                "Setup Required",
                "Virtual environment (.venv) not found. Would you like to create it and install all dependencies automatically?\n\nThis may take a few minutes.",
            )
            root.destroy()
            if not confirm:
                sys.exit(0)
        except Exception:
            pass
            
        import venv
        print("Creating virtual environment...", flush=True)
        venv.create(venv_dir, with_pip=True)
        
        req_file = app_dir / "requirements.txt"
        if not req_file.exists():
            req_file.write_text("\n".join([
                "numpy",
                "pandas",
                "scipy",
                "scikit-learn",
                "lightgbm",
                "mne>=1.6.0",
                "yasa",
                "antropy",
                "joblib",
                "safetensors",
                "transformers>=4.40.0,<5.0.0",
                "torch",
                "matplotlib",
                "gssc",
                "physioex",
                "braindecode",
                "lunapi",
                "lspopt",
                "mne-bids",
                "mne-icalabel",
                "autoreject",
                "pyedflib",
                "mne-connectivity",
            ]) + "\n")
            
        pip_exe = venv_dir / bin_dir / ("pip.exe" if os.name == "nt" else "pip")
        print("Installing dependencies...", flush=True)
        subprocess.run([str(pip_exe), "install", "-r", str(req_file)], check=True)
        print("Setup complete.", flush=True)
        
    args = [str(python_exe)] + sys.argv
    if os.name != "nt":
        os.execv(str(python_exe), args)
    else:
        sys.exit(subprocess.run(args).returncode)

# Run bootstrap before other imports
bootstrap()

import queue
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from tkinter.scrolledtext import ScrolledText

if __package__:
    from .scorer import scan_channels
    from .algorithms import available_algorithms
else:
    from scorer import scan_channels
    from algorithms import available_algorithms


SUPPORTED_FILES = (
    ("EEG data", "*.edf *.EDF *.bdf *.BDF *.gdf *.GDF *.fif *.FIF *.set *.SET"),
    ("All files", "*.*"),
)


class SleepScoringApp:
    def __init__(self, root: tk.Tk) -> None:
        self.root = root
        self.root.title("Automated Sleep Scoring")
        self.root.geometry("980x760")
        self.root.minsize(860, 640)

        self.data_file = tk.StringVar()
        self.output_dir = tk.StringVar()
        self.algorithm = tk.StringVar(value="yasa")
        self.sequence_correction = tk.BooleanVar(value=False)
        self.status = tk.StringVar(value="Choose a data file to scan channels.")
        self.algorithms = available_algorithms()

        self.channel_vars: dict[str, tk.BooleanVar] = {}
        self.ref_vars: dict[str, tk.BooleanVar] = {}
        self.eog_vars: dict[str, tk.BooleanVar] = {}
        self.emg_vars: dict[str, tk.BooleanVar] = {}
        self.guessed_eeg_channels: set[str] = set()
        self.log_queue: queue.Queue[str] = queue.Queue()

        self._build()
        self._drain_log_queue()

    def _build(self) -> None:
        main = ttk.Frame(self.root, padding=14)
        main.grid(row=0, column=0, sticky="nsew")
        self.root.rowconfigure(0, weight=1)
        self.root.columnconfigure(0, weight=1)
        main.columnconfigure(1, weight=1)
        main.rowconfigure(5, weight=1)
        main.rowconfigure(6, weight=1)

        ttk.Label(main, text="Data File(s)").grid(row=0, column=0, sticky="w", pady=4)
        ttk.Entry(main, textvariable=self.data_file).grid(row=0, column=1, sticky="ew", padx=8, pady=4)
        ttk.Button(main, text="Browse", command=self.browse_file).grid(row=0, column=2, sticky="ew", pady=4)

        ttk.Label(main, text="Output Folder").grid(row=1, column=0, sticky="w", pady=4)
        ttk.Entry(main, textvariable=self.output_dir).grid(row=1, column=1, sticky="ew", padx=8, pady=4)
        ttk.Button(main, text="Browse", command=self.browse_output).grid(row=1, column=2, sticky="ew", pady=4)

        ttk.Label(main, text="Algorithm").grid(row=2, column=0, sticky="w", pady=4)
        algo = ttk.Combobox(
            main,
            textvariable=self.algorithm,
            state="readonly",
            values=tuple(sorted(self.algorithms)),
        )
        algo.grid(row=2, column=1, sticky="w", padx=8, pady=4)
        algo.bind("<<ComboboxSelected>>", lambda event: self._update_algorithm_description())
        ttk.Button(main, text="Scan Channels", command=self.scan_selected_file).grid(row=2, column=2, sticky="ew", pady=4)

        correction_row = ttk.Frame(main)
        correction_row.grid(row=3, column=1, sticky="w", padx=8, pady=(2, 4))
        ttk.Checkbutton(
            correction_row,
            text="Apply SleepGPT sequence correction after base scorer",
            variable=self.sequence_correction,
        ).pack(side=tk.LEFT)

        self.meta_label = ttk.Label(main, textvariable=self.status)
        self.meta_label.grid(row=4, column=0, columnspan=3, sticky="w", pady=(6, 10))

        selector = ttk.PanedWindow(main, orient=tk.HORIZONTAL)
        selector.grid(row=5, column=0, columnspan=3, sticky="nsew")
        self.eeg_frame = self._scrollable_group(selector, "EEG Channels")
        self.ref_frame = self._scrollable_group(selector, "Reference Channels")
        self.aux_frame = self._scrollable_group(selector, "EOG / EMG Channels")

        buttons = ttk.Frame(main)
        buttons.grid(row=7, column=0, columnspan=3, sticky="ew", pady=10)
        ttk.Button(buttons, text="Select All EEG", command=self.select_all_eeg).pack(side=tk.LEFT)
        ttk.Button(buttons, text="Clear EEG", command=self.clear_eeg).pack(side=tk.LEFT, padx=8)
        
        self.run_button = ttk.Button(buttons, text="Run Scoring", command=self.run_scoring)
        self.run_button.pack(side=tk.RIGHT)

        self.console = ScrolledText(main, height=11, state="disabled", wrap="word")
        self.console.grid(row=6, column=0, columnspan=3, sticky="nsew", pady=(12, 0))
        self._update_algorithm_description()

    def _update_algorithm_description(self) -> None:
        algorithm = self.algorithms.get(self.algorithm.get())
        if algorithm:
            self.status.set(f"{algorithm.label}: {algorithm.description}")

    def _bind_scroll(self, widget: tk.Widget, canvas: tk.Canvas) -> None:
        def _on_mousewheel(event):
            if event.num == 4:
                canvas.yview_scroll(-1, "units")
            elif event.num == 5:
                canvas.yview_scroll(1, "units")
            else:
                if sys.platform == "darwin":
                    canvas.yview_scroll(int(-1 * event.delta), "units")
                else:
                    canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")
        if sys.platform == "linux":
            widget.bind("<Button-4>", _on_mousewheel, add="+")
            widget.bind("<Button-5>", _on_mousewheel, add="+")
        else:
            widget.bind("<MouseWheel>", _on_mousewheel, add="+")

    def _scrollable_group(self, parent: ttk.PanedWindow, title: str) -> ttk.Frame:
        outer = ttk.Frame(parent, padding=8)
        parent.add(outer, weight=1)
        ttk.Label(outer, text=title, font=("", 12, "bold")).pack(anchor="w")
        canvas = tk.Canvas(outer, height=230, highlightthickness=0)
        scrollbar = ttk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        inner = ttk.Frame(canvas)
        inner.bind("<Configure>", lambda event: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=inner, anchor="nw")
        canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self._bind_scroll(canvas, canvas)
        self._bind_scroll(inner, canvas)
        inner.canvas_ref = canvas
        return inner

    def browse_file(self) -> None:
        filenames = filedialog.askopenfilenames(title="Select EEG data file(s)", filetypes=SUPPORTED_FILES)
        if filenames:
            self.data_file.set("; ".join(filenames))
            if not self.output_dir.get():
                self.output_dir.set(str(Path(filenames[0]).parent))
            self.scan_selected_file()

    def browse_output(self) -> None:
        directory = filedialog.askdirectory(title="Select output folder")
        if directory:
            self.output_dir.set(directory)

    def _clear_channel_widgets(self) -> None:
        for frame in (self.eeg_frame, self.ref_frame, self.aux_frame):
            for child in frame.winfo_children():
                child.destroy()
        self.channel_vars.clear()
        self.ref_vars.clear()
        self.eog_vars.clear()
        self.emg_vars.clear()
        self.guessed_eeg_channels.clear()

    def scan_selected_file(self) -> None:
        data_file_str = self.data_file.get().strip()
        if not data_file_str:
            messagebox.showerror("Missing file", "Choose a data file first.")
            return
        files = [f.strip() for f in data_file_str.split(";") if f.strip()]
        if not files:
            messagebox.showerror("Missing file", "Choose a data file first.")
            return

        first_file = files[0]
        try:
            # Patch numpy before scan_channels just in case
            import numpy as np
            if not hasattr(np, "trapz") and hasattr(np, "trapezoid"):
                np.trapz = np.trapezoid
            if not hasattr(np, "in1d"):
                np.in1d = np.isin
                
            channels, guesses, sfreq, duration = scan_channels(first_file)
        except Exception as exc:
            messagebox.showerror("Scan failed", str(exc))
            return

        self._clear_channel_widgets()
        guessed_eeg = set(guesses.eeg)
        self.guessed_eeg_channels = guessed_eeg
        guessed_ref = set(guesses.ref)
        guessed_eog = set(guesses.eog[:2])
        guessed_emg = set(guesses.emg[:2])

        for channel in channels:
            eeg_var = tk.BooleanVar(value=channel in guessed_eeg)
            self.channel_vars[channel] = eeg_var
            btn = ttk.Checkbutton(self.eeg_frame, text=channel, variable=eeg_var)
            btn.pack(anchor="w")
            self._bind_scroll(btn, self.eeg_frame.canvas_ref)

            if channel in guesses.ref:
                ref_var = tk.BooleanVar(value=channel in guessed_ref)
                self.ref_vars[channel] = ref_var
                btn = ttk.Checkbutton(self.ref_frame, text=channel, variable=ref_var)
                btn.pack(anchor="w")
                self._bind_scroll(btn, self.ref_frame.canvas_ref)

            if channel in guesses.eog:
                eog_var = tk.BooleanVar(value=channel in guessed_eog)
                self.eog_vars[channel] = eog_var
                btn = ttk.Checkbutton(self.aux_frame, text=f"EOG: {channel}", variable=eog_var)
                btn.pack(anchor="w")
                self._bind_scroll(btn, self.aux_frame.canvas_ref)

            if channel in guesses.emg:
                emg_var = tk.BooleanVar(value=channel in guessed_emg)
                self.emg_vars[channel] = emg_var
                btn = ttk.Checkbutton(self.aux_frame, text=f"EMG: {channel}", variable=emg_var)
                btn.pack(anchor="w")
                self._bind_scroll(btn, self.aux_frame.canvas_ref)

        file_desc = f"{len(files)} files | " if len(files) > 1 else ""
        self.status.set(
            f"{file_desc}{len(channels)} channels | {sfreq:g} Hz | {duration / 3600:.2f} hours | "
            f"guessed {len(guesses.eeg)} EEG, {len(guesses.ref)} refs"
        )

    def select_all_eeg(self) -> None:
        for channel, var in self.channel_vars.items():
            var.set(channel in self.guessed_eeg_channels)

    def clear_eeg(self) -> None:
        for var in self.channel_vars.values():
            var.set(False)

    def selected(self, mapping: dict[str, tk.BooleanVar]) -> list[str]:
        return [name for name, var in mapping.items() if var.get()]

    def run_scoring(self) -> None:
        data_file_str = self.data_file.get().strip()
        if not data_file_str:
            messagebox.showerror("Missing selection", "Choose a data file first.")
            return
        files = [f.strip() for f in data_file_str.split(";") if f.strip()]
        if not files:
            messagebox.showerror("Missing selection", "Choose a data file first.")
            return

        out_dir = self.output_dir.get().strip() or str(Path(files[0]).parent)
        eeg = self.selected(self.channel_vars)
        if not eeg:
            messagebox.showerror("Missing selection", "Choose at least one EEG channel.")
            return

        self.run_button.configure(state="disabled")

        worker = threading.Thread(
            target=self._score_worker,
            args=(files, out_dir, eeg, self.selected(self.ref_vars), self.selected(self.eog_vars), self.selected(self.emg_vars)),
            daemon=True,
        )
        worker.start()

    def _score_worker(
        self,
        files: list[str],
        out_dir: str,
        eeg: list[str],
        refs: list[str],
        eog: list[str],
        emg: list[str],
    ) -> None:
        import sys
        import time

        cli_path = Path(__file__).resolve().parent / "cli.py"

        try:
            self._log(f"Starting automated sleep scoring batch job on {len(files)} file(s).")
            
            for index, file_path in enumerate(files, 1):
                self._log(f"\n==================================================")
                self._log(f"Processing file {index} of {len(files)}: {Path(file_path).name}")
                self._log(f"==================================================")
                file_start = time.perf_counter()
                
                cmd = [
                    sys.executable,
                    str(cli_path),
                    file_path,
                    "--algorithm", self.algorithm.get(),
                    "--sequence-correction", "sleepgpt" if self.sequence_correction.get() else "none",
                    "--eeg", ",".join(eeg),
                    "--ref", ",".join(refs),
                    "--eog", ",".join(eog),
                    "--emg", ",".join(emg),
                ]
                if out_dir:
                    cmd += ["--out-dir", out_dir]
                
                env = os.environ.copy()
                env["PYTHONPATH"] = str(cli_path.parent.parent) + os.pathsep + env.get("PYTHONPATH", "")
                
                process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    env=env,
                )
                
                if process.stdout:
                    for line in process.stdout:
                        self._log(line)
                
                process.wait()
                file_duration = time.perf_counter() - file_start
                if process.returncode != 0:
                    self._log(f"Subprocess failed for {Path(file_path).name} with exit status {process.returncode} (duration: {file_duration:.1f}s).")
                else:
                    self._log(f"Successfully scored {Path(file_path).name} (duration: {file_duration:.1f}s).")

            self._log("\nBatch scoring completed.")
            self.status.set(f"Completed scoring {len(files)} file(s).")
        except Exception as exc:
            self._log(f"Failed: {exc}")
            messagebox.showerror("Scoring failed", str(exc))
        finally:
            self.run_button.configure(state="normal")

    def _log(self, message: str) -> None:
        self.log_queue.put(str(message).rstrip() + "\n")

    def _drain_log_queue(self) -> None:
        try:
            while True:
                message = self.log_queue.get_nowait()
                self.console.configure(state="normal")
                self.console.insert("end", message)
                self.console.see("end")
                self.console.configure(state="disabled")
        except queue.Empty:
            pass
        self.root.after(80, self._drain_log_queue)


def main() -> None:
    root = tk.Tk()
    SleepScoringApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
