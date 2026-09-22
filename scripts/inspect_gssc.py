#!/usr/bin/env python3
import torch
import os

net_name = "dist/autoscore-backend/_internal/gssc/nets/sig_net_v1.pt"
con_net_name = "dist/autoscore-backend/_internal/gssc/nets/gru_net_v1.pt"

print("Loading GSSC models...")
net = torch.load(net_name, weights_only=False).eval()
con_net = torch.load(con_net_name, weights_only=False).eval()

print("net type:", type(net))
print("con_net type:", type(con_net))

# Test net forward
# In backend/algorithms.py:
# sigs: dict with 'eeg' and/or 'eog'
sig_len = 2560
dummy_eeg = torch.randn(4, 1, sig_len)
dummy_eog = torch.randn(4, 1, sig_len)

with torch.no_grad():
    rep_eeg = net({"eeg": dummy_eeg}, rep_output="rep_only")
    print("rep_eeg shape:", rep_eeg.shape)
    rep_both = net({"eeg": dummy_eeg, "eog": dummy_eog}, rep_output="rep_only")
    print("rep_both shape:", rep_both.shape)
    
    reps = rep_both.swapaxes(-1, 1) # (1, 4, 128)
    hidden = torch.zeros(10, 1, 256)
    y, hidden_out = con_net(reps, hidden)
    print("con_net y shape:", y.shape)
