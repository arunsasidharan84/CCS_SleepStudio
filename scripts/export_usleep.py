#!/usr/bin/env python3
import os
import json
import torch
import numpy as np
from safetensors.torch import load_file
from braindecode.models import USleep
from braindecode.models.usleep import _DecoderBlock

def clean_crop_tensors(x1, x2, axis=-1):
    d = min(x1.shape[axis], x2.shape[axis])
    return x1[..., :d], x2[..., :d]

_DecoderBlock._crop_tensors_to_match = staticmethod(clean_crop_tensors)

print("Loading USleep architecture and weights...")
weights_path = "backend/models/usleep_braindecode/params.safetensors"
if not os.path.exists(weights_path):
    raise FileNotFoundError(f"Missing {weights_path}")

model = USleep(n_chans=2, sfreq=100, n_times=3000, depth=12, n_outputs=5)
state = load_file(weights_path)
model.load_state_dict(state, strict=True)
model.eval()

# Dummy input: batch_size=1, sequence_length=3, n_chans=2, n_times=3000
dummy_input = torch.randn(1, 3, 2, 3000, dtype=torch.float32)

# Output test
with torch.no_grad():
    test_out = model(dummy_input)
    # y_pred has shape (B, 5, 3)
    # central epoch is index 1
    mid_logits = test_out[:, :, 1]
    probs = torch.softmax(mid_logits, dim=1).numpy().tolist()
    print("USleep forward pass OK! Output shape:", test_out.shape, "Probs:", probs)

os.makedirs("analyseNidra/assets/models/usleep", exist_ok=True)
onnx_path = "analyseNidra/assets/models/usleep/usleep.onnx"
print(f"Exporting ONNX model to {onnx_path}...")
torch.onnx.export(
    model,
    dummy_input,
    onnx_path,
    input_names=["input"],
    output_names=["output"],
    dynamic_axes={
        "input": {0: "batch_size"},
        "output": {0: "batch_size"},
    },
    opset_version=17,
    dynamo=False,
)
print("ONNX export complete!")

# Save binary test vector
dummy_input.numpy().astype(np.float32).tofile("analyseNidra/assets/models/usleep/usleep_test_input.bin")

test_vector = {
    "input_shape": list(dummy_input.shape),
    "expected_output_shape": list(test_out.shape),
    "expected_probs": probs[0],
}
with open("analyseNidra/assets/models/usleep/usleep_test_vector.json", "w") as f:
    json.dump(test_vector, f, indent=2)
print("Saved test vector!")
