#!/usr/bin/env python3
import os
import torch
import torch.nn as nn

net_name = "dist/autoscore-backend/_internal/gssc/nets/sig_net_v1.pt"
con_net_name = "dist/autoscore-backend/_internal/gssc/nets/gru_net_v1.pt"

os.makedirs("analyseNidra/assets/models/gssc", exist_ok=True)

res_sleep = torch.load(net_name, weights_only=False).eval()
sleep_gru = torch.load(con_net_name, weights_only=False).eval()

# 1. EEG-only wrapper
class GsscEegWrapper(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, eeg):
        return self.m({"eeg": eeg}, rep_output="rep_only").swapaxes(-1, 1)

# 2. EOG-only wrapper
class GsscEogWrapper(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, eog):
        return self.m({"eog": eog}, rep_output="rep_only").swapaxes(-1, 1)

# 3. Both wrapper
class GsscBothWrapper(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, eeg, eog):
        return self.m({"eeg": eeg, "eog": eog}, rep_output="rep_only").swapaxes(-1, 1)

# 4. GRU wrapper
class GsscGruWrapper(nn.Module):
    def __init__(self, gru):
        super().__init__()
        self.gru = gru
    def forward(self, reps, hidden):
        y, _ = self.gru(reps, hidden)
        return y[:, 0, :] # logits (E, 5)

print("Exporting GSSC EEG-only encoder...")
eeg_mod = GsscEegWrapper(res_sleep)
dummy_eeg = torch.randn(1, 1, 2560)
torch.onnx.export(
    eeg_mod,
    dummy_eeg,
    "analyseNidra/assets/models/gssc/gssc_eeg.onnx",
    input_names=["eeg"],
    output_names=["reps"],
    dynamic_axes={"eeg": {0: "num_epochs"}, "reps": {0: "num_epochs"}},
    opset_version=17,
    dynamo=False,
)

print("Exporting GSSC EOG-only encoder...")
eog_mod = GsscEogWrapper(res_sleep)
dummy_eog = torch.randn(1, 1, 2560)
torch.onnx.export(
    eog_mod,
    dummy_eog,
    "analyseNidra/assets/models/gssc/gssc_eog.onnx",
    input_names=["eog"],
    output_names=["reps"],
    dynamic_axes={"eog": {0: "num_epochs"}, "reps": {0: "num_epochs"}},
    opset_version=17,
    dynamo=False,
)

print("Exporting GSSC Both encoder...")
both_mod = GsscBothWrapper(res_sleep)
dummy_eog = torch.randn(1, 1, 2560)
torch.onnx.export(
    both_mod,
    (dummy_eeg, dummy_eog),
    "analyseNidra/assets/models/gssc/gssc_both.onnx",
    input_names=["eeg", "eog"],
    output_names=["reps"],
    dynamic_axes={"eeg": {0: "num_epochs"}, "eog": {0: "num_epochs"}, "reps": {0: "num_epochs"}},
    opset_version=17,
    dynamo=False,
)

print("Exporting GSSC GRU...")
gru_mod = GsscGruWrapper(sleep_gru)
dummy_reps = torch.randn(1, 1, 512)
dummy_hidden = torch.zeros(10, 1, 256)
torch.onnx.export(
    gru_mod,
    (dummy_reps, dummy_hidden),
    "analyseNidra/assets/models/gssc/gssc_gru.onnx",
    input_names=["reps", "hidden"],
    output_names=["logits"],
    dynamic_axes={"reps": {0: "num_epochs"}, "logits": {0: "num_epochs"}},
    opset_version=17,
    dynamo=False,
)

print("ALL GSSC ONNX MODELS EXPORTED!")
