#!/usr/bin/env python3
import os
import json
import torch
import numpy as np

from physioex.train.models import load_model

os.makedirs("analyseNidra/assets/models/physioex", exist_ok=True)

for model_name in ["seqsleepnet", "sleeptransformer"]:
    print(f"Loading PhysioEx model {model_name}...")
    model = load_model(
        model_name,
        model_kwargs={"sequence_length": 21, "in_channels": 1},
        device="cpu",
        softmax=False,
        summary=False,
    ).eval()
    
    # Input shape: (batch_size, sequence_length=21, in_channels=1, n_freq=29, n_time=129)
    dummy_input = torch.randn(1, 21, 1, 29, 129, dtype=torch.float32)
    
    with torch.no_grad():
        test_out = model(dummy_input)
        print(f"{model_name} forward pass OK! Output shape:", test_out.shape)
        center = 21 // 2
        probs = torch.softmax(test_out[:, center, :], dim=1).numpy().tolist()
    
    onnx_path = f"analyseNidra/assets/models/physioex/{model_name}.onnx"
    print(f"Exporting to {onnx_path}...")
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
    dummy_input.numpy().astype(np.float32).tofile(f"analyseNidra/assets/models/physioex/{model_name}_test_input.bin")
    test_vector = {
        "input_shape": list(dummy_input.shape),
        "expected_output_shape": list(test_out.shape),
        "expected_probs": probs[0],
    }
    with open(f"analyseNidra/assets/models/physioex/{model_name}_test_vector.json", "w") as f:
        json.dump(test_vector, f, indent=2)

    print(f"Exported {model_name} and saved test vectors successfully!")

print("ALL PHYSIOEX MODELS EXPORTED!")
