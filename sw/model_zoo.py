"""
model_zoo.py — Unified model training, quantization, and export for CIM SoC.

Supports multiple architectures:
  - 'mlp':     784→128→10 (2-layer MLP)
  - 'lenet5':  Conv1→Pool→Conv2→Pool→FC3→FC4→FC5
  - 'custom':  user-defined list of layers

All models trained on raw [0,1] MNIST pixels (no Normalize).
All quantization uses fixed input scale=1/255, symmetric weights.

Usage:
  from model_zoo import build_model, train, quantize, int8_infer, export_hex

  model = build_model('lenet5')
  train(model, epochs=15, seed=42)
  qparams = quantize(model)
  pred, outputs = int8_infer(image_u8, qparams)
  export_hex(qparams, output_dir, test_images, labels)
"""

import torch
import torch.nn as nn
import torch.optim as optim
from torchvision import datasets, transforms
import numpy as np
import os, json, shutil

# ============================================================================
# Hardware constants (cim_pkg.sv)
# ============================================================================
TILE_ROWS = 16
TILE_COLS = 16
ELEMS_PER_CHUNK = 4
CHUNKS_PER_ROW = 4
CHUNKS_PER_TILE = 64
MAX_IN_DIM = 784
MAX_OUT_DIM = 128


# ============================================================================
# Model definitions
# ============================================================================
class MnistMLP(nn.Module):
    """784→128→10 MLP."""

    arch_name = "mlp"

    def __init__(self):
        super().__init__()
        self.fc1 = nn.Linear(784, 128)
        self.relu = nn.ReLU()
        self.fc2 = nn.Linear(128, 10)

    def forward(self, x):
        x = x.view(-1, 784)
        return self.fc2(self.relu(self.fc1(x)))


class LeNet5(nn.Module):
    """LeNet-5 for MNIST 28x28."""

    arch_name = "lenet5"

    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 6, 5)
        self.conv2 = nn.Conv2d(6, 16, 5)
        self.fc3 = nn.Linear(256, 120)
        self.fc4 = nn.Linear(120, 84)
        self.fc5 = nn.Linear(84, 10)
        self.relu = nn.ReLU()
        self.pool = nn.MaxPool2d(2, 2)

    def forward(self, x):
        x = self.pool(self.relu(self.conv1(x)))
        x = self.pool(self.relu(self.conv2(x)))
        x = x.view(-1, 256)
        x = self.relu(self.fc3(x))
        x = self.relu(self.fc4(x))
        return self.fc5(x)


# Registry
MODEL_REGISTRY = {
    "mlp": MnistMLP,
    "lenet5": LeNet5,
}


def build_model(arch="mlp"):
    if arch not in MODEL_REGISTRY:
        raise ValueError(
            f"Unknown arch '{arch}'. Choose from: {list(MODEL_REGISTRY.keys())}"
        )
    return MODEL_REGISTRY[arch]()


# ============================================================================
# Training
# ============================================================================
def get_dataloaders(batch_size=128):
    transform = transforms.Compose([transforms.ToTensor()])
    train_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    test_set = datasets.MNIST("./data", train=False, download=True, transform=transform)
    train_loader = torch.utils.data.DataLoader(
        train_set, batch_size=batch_size, shuffle=True
    )
    test_loader = torch.utils.data.DataLoader(test_set, batch_size=1000)
    return train_loader, test_loader


def train(model, epochs=10, lr=0.001, device="cpu", seed=None):
    if seed is not None:
        np.random.seed(seed)
        torch.manual_seed(seed)

    model = model.to(device)
    train_loader, test_loader = get_dataloaders()
    optimizer = optim.Adam(model.parameters(), lr=lr)
    criterion = nn.CrossEntropyLoss()

    print(f"Training {model.arch_name} for {epochs} epochs (seed={seed})")
    for epoch in range(epochs):
        model.train()
        loss_sum = 0
        for data, target in train_loader:
            data, target = data.to(device), target.to(device)
            optimizer.zero_grad()
            loss = criterion(model(data), target)
            loss.backward()
            optimizer.step()
            loss_sum += loss.item()

        model.eval()
        correct = sum(
            model(d.to(device)).argmax(1).eq(t.to(device)).sum().item()
            for d, t in test_loader
        )
        acc = 100.0 * correct / 10000
        print(
            f"  Epoch {epoch + 1}/{epochs}: loss={loss_sum / len(train_loader):.4f}, acc={acc:.2f}%"
        )
    return acc


# ============================================================================
# Quantization utilities
# ============================================================================
def _sym_scale(t):
    m = t.abs().max().item()
    return m / 127.0 if m > 0 else 1e-8


def _quant_sym(t, s):
    return torch.clamp(torch.round(t / s), -128, 127).to(torch.int8)


def _quant_bias(b, s_in, s_w):
    return torch.clamp(torch.round(b / (s_in * s_w)), -(2**31), 2**31 - 1).to(
        torch.int32
    )


def _requant_params(s_in, s_w, s_out, shift=16):
    M = (s_in * s_w) / s_out
    return max(1, int(round(M * (1 << shift)))), shift


# ============================================================================
# Quantize: builds layer descriptors
# ============================================================================
def _get_layer_descriptors(model):
    """Return ordered list of (name, type, module_or_config) for quantization."""
    name = model.arch_name
    if name == "mlp":
        return [
            ("fc1", "fc", model.fc1, {"relu": True}),
            ("fc2", "fc", model.fc2, {"relu": False}),
        ]
    elif name == "lenet5":
        return [
            ("conv1", "conv", model.conv1, {"relu": True, "stride": 1, "padding": 0}),
            ("pool1", "pool", None, {"kernel": 2, "stride": 2}),
            ("conv2", "conv", model.conv2, {"relu": True, "stride": 1, "padding": 0}),
            ("pool2", "pool", None, {"kernel": 2, "stride": 2}),
            ("fc3", "fc", model.fc3, {"relu": True}),
            ("fc4", "fc", model.fc4, {"relu": True}),
            ("fc5", "fc", model.fc5, {"relu": False}),
        ]
    raise ValueError(f"No layer descriptors for arch '{name}'")


def _calibrate(model, device="cpu"):
    """Run calibration to find activation ranges per layer."""
    transform = transforms.Compose([transforms.ToTensor()])
    cal_set = datasets.MNIST("./data", train=True, download=True, transform=transform)
    cal_loader = torch.utils.data.DataLoader(cal_set, batch_size=500, shuffle=False)

    ranges = {}
    model.eval()
    with torch.no_grad():
        for data, _ in cal_loader:
            data = data.to(device)
            if model.arch_name == "mlp":
                x = data.view(-1, 784)
                o1 = model.relu(model.fc1(x))
                o2 = model.fc2(o1)
                for n, t in [("fc1_out", o1), ("fc2_out", o2)]:
                    if n not in ranges:
                        ranges[n] = [float("inf"), float("-inf")]
                    ranges[n][0] = min(ranges[n][0], t.min().item())
                    ranges[n][1] = max(ranges[n][1], t.max().item())
            elif model.arch_name == "lenet5":
                c1 = model.relu(model.conv1(data))
                p1 = model.pool(c1)
                c2 = model.relu(model.conv2(p1))
                p2 = model.pool(c2)
                f = p2.view(-1, 256)
                o3 = model.relu(model.fc3(f))
                o4 = model.relu(model.fc4(o3))
                o5 = model.fc5(o4)
                for n, t in [
                    ("conv1_out", c1),
                    ("conv2_out", c2),
                    ("fc3_out", o3),
                    ("fc4_out", o4),
                    ("fc5_out", o5),
                ]:
                    if n not in ranges:
                        ranges[n] = [float("inf"), float("-inf")]
                    ranges[n][0] = min(ranges[n][0], t.min().item())
                    ranges[n][1] = max(ranges[n][1], t.max().item())
    return ranges


def quantize(model, device="cpu"):
    """Full PTQ. Returns dict with 'layers' list and 'arch'."""
    model = model.to(device).eval()
    print(f"\nQuantizing {model.arch_name}...")
    ranges = _calibrate(model, device)

    s_in = 1.0 / 255.0  # fixed input scale
    descriptors = _get_layer_descriptors(model)
    layers = []
    current_scale = s_in

    for name, ltype, mod, cfg in descriptors:
        if ltype == "pool":
            layers.append({"name": name, "type": "pool", **cfg})
            # pool doesn't change scale
            continue

        # Weight quantization
        w = mod.weight.data
        s_w = _sym_scale(w)
        w_q = _quant_sym(w, s_w).cpu()

        # Output scale from calibration
        range_key = f"{name}_out"
        if range_key in ranges:
            out_abs = max(abs(ranges[range_key][0]), abs(ranges[range_key][1]))
            s_out = out_abs / 127.0 if out_abs > 0 else 1e-8
        else:
            s_out = current_scale * s_w  # fallback

        # Bias
        b_q = _quant_bias(mod.bias.data, current_scale, s_w).cpu()

        # Requant
        mult, shift = _requant_params(current_scale, s_w, s_out)

        info = {
            "name": name,
            "type": ltype,
            "weight": w_q.numpy(),
            "bias": b_q.numpy(),
            "zp": 0,
            "mult": mult,
            "shift": shift,
            "relu": cfg.get("relu", False),
            "s_w": s_w,
            "s_out": s_out,
        }
        if ltype == "conv":
            C_out, C_in, Kh, Kw = w.shape
            info.update(
                {
                    "C_out": C_out,
                    "C_in": C_in,
                    "K_h": Kh,
                    "K_w": Kw,
                    "stride": cfg["stride"],
                    "padding": cfg["padding"],
                }
            )
        elif ltype == "fc":
            info.update({"in_dim": w.shape[1], "out_dim": w.shape[0]})

        print(f"  {name}: s_w={s_w:.6f}, s_out={s_out:.6f}, mult={mult}, shift={shift}")
        layers.append(info)
        current_scale = s_out

    return {"arch": model.arch_name, "layers": layers}


# ============================================================================
# Bit-accurate INT8 inference
# ============================================================================
def _hw_mvm(x_u8, w_i8, b_i32, zp, mult, shift, relu):
    x_eff = np.clip(x_u8.astype(np.int32) - zp, 0, 511)
    acc = w_i8.astype(np.int32) @ x_eff.astype(np.int32) + b_i32.astype(np.int32)
    if relu:
        acc = np.maximum(acc, 0)
    out = np.zeros(len(acc), dtype=np.int8)
    for i in range(len(acc)):
        prod = int(acc[i]) * int(mult)
        shifted = (prod + (1 << (shift - 1))) >> shift if shift > 0 else prod
        out[i] = np.int8(max(-128, min(127, shifted)))
    return out


def _im2col(feat, kh, kw, stride=1, padding=0):
    C, H, W = feat.shape
    if padding > 0:
        p = np.zeros((C, H + 2 * padding, W + 2 * padding), dtype=feat.dtype)
        p[:, padding : padding + H, padding : padding + W] = feat
        feat = p
    Hp, Wp = feat.shape[1], feat.shape[2]
    oh = (Hp - kh) // stride + 1
    ow = (Wp - kw) // stride + 1
    col = np.zeros((C * kh * kw, oh * ow), dtype=feat.dtype)
    idx = 0
    for i in range(oh):
        for j in range(ow):
            col[:, idx] = feat[
                :, i * stride : i * stride + kh, j * stride : j * stride + kw
            ].flatten()
            idx += 1
    return col, oh, ow


def _maxpool(feat, k=2, s=2):
    C, H, W = feat.shape
    oh, ow = H // s, W // s
    out = np.zeros((C, oh, ow), dtype=feat.dtype)
    for c in range(C):
        for i in range(oh):
            for j in range(ow):
                out[c, i, j] = feat[c, i * s : i * s + k, j * s : j * s + k].max()
    return out


def int8_infer(image_u8, qparams):
    """
    Bit-accurate INT8 inference for any supported architecture.
    image_u8: [784] UINT8 flat array (28x28 image, pixel*255)
    Returns: (pred_class, final_output, intermediates_dict)
    """
    arch = qparams["arch"]
    if arch == "mlp":
        x = image_u8
    else:
        x = image_u8.reshape(1, 28, 28)

    intermediates = {}
    for layer in qparams["layers"]:
        name = layer["name"]
        if layer["type"] == "conv":
            w = layer["weight"]
            C_out = layer["C_out"]
            w2d = w.reshape(C_out, -1)
            col, oh, ow = _im2col(
                x, layer["K_h"], layer["K_w"], layer["stride"], layer["padding"]
            )
            out = np.zeros((C_out, oh * ow), dtype=np.int8)
            for p in range(oh * ow):
                out[:, p] = _hw_mvm(
                    col[:, p],
                    w2d,
                    layer["bias"],
                    layer["zp"],
                    layer["mult"],
                    layer["shift"],
                    layer["relu"],
                )
            x = out.reshape(C_out, oh, ow)
        elif layer["type"] == "pool":
            x = _maxpool(x.view(np.int8), layer["kernel"], layer["stride"]).view(
                np.uint8
            )
        elif layer["type"] == "fc":
            if x.ndim > 1:
                x = x.flatten()
            if hasattr(x, "dtype") and x.dtype == np.int8:
                x = x.view(np.uint8)
            x = _hw_mvm(
                x,
                layer["weight"],
                layer["bias"],
                layer["zp"],
                layer["mult"],
                layer["shift"],
                layer["relu"],
            )
        intermediates[name] = np.copy(x) if isinstance(x, np.ndarray) else x

    final = x.flatten() if isinstance(x, np.ndarray) else np.array(x)
    return int(np.argmax(final)), final, intermediates


# ============================================================================
# Hex export
# ============================================================================
def _w2chunks(w, tr=TILE_ROWS, tc=TILE_COLS):
    od, id_ = w.shape
    nob = (od + tr - 1) // tr
    nib = (id_ + tc - 1) // tc
    chunks = []
    for ob in range(nob):
        for ib in range(nib):
            for ch in range(CHUNKS_PER_TILE):
                r = ch // CHUNKS_PER_ROW
                cg = ch % CHUNKS_PER_ROW
                word = 0
                for b in range(ELEMS_PER_CHUNK):
                    oi = ob * tr + r
                    ii = ib * tc + cg * ELEMS_PER_CHUNK + b
                    if oi < od and ii < id_:
                        word |= (int(w[oi, ii]) & 0xFF) << (b * 8)
                chunks.append(word)
    return chunks


def _save(lines, path):
    with open(path, "w") as f:
        for l in lines:
            f.write(l + "\n")


def export_hex(qparams, output_dir, test_images=None, test_labels=None, num_test=20):
    """
    Export all hex files for PYNQ deployment.
    test_images: list of [784] UINT8 arrays
    test_labels: list of int labels
    """
    os.makedirs(output_dir, exist_ok=True)

    # Layer weights + bias
    compute_layers = [l for l in qparams["layers"] if l["type"] in ("conv", "fc")]
    for layer in compute_layers:
        w = layer["weight"]
        if w.ndim == 4:
            w = w.reshape(w.shape[0], -1)
        _save(
            [f"{v:08x}" for v in _w2chunks(w)],
            f"{output_dir}/{layer['name']}_weight_tiles.hex",
        )
        _save(
            [f"{int(v) & 0xFFFFFFFF:08x}" for v in layer["bias"]],
            f"{output_dir}/{layer['name']}_bias.hex",
        )

    # Quant params + zero points
    qp = []
    zps = []
    for l in compute_layers:
        qp.extend([f"{l['mult'] & 0xFFFFFFFF:08x}", f"{l['shift'] & 0xFFFFFFFF:08x}"])
        zps.append(f"{l['zp'] & 0xFFFFFFFF:08x}")
    _save(qp, f"{output_dir}/quant_params.hex")
    _save(zps, f"{output_dir}/zero_points.hex")

    # Layer info
    info = {"arch": qparams["arch"], "layers": []}
    for l in qparams["layers"]:
        entry = {"name": l["name"], "type": l["type"]}
        if l["type"] == "conv":
            entry.update(
                {
                    k: l[k]
                    for k in [
                        "C_out",
                        "C_in",
                        "K_h",
                        "K_w",
                        "stride",
                        "padding",
                        "relu",
                        "mult",
                        "shift",
                        "zp",
                    ]
                }
            )
        elif l["type"] == "fc":
            entry.update(
                {k: l[k] for k in ["in_dim", "out_dim", "relu", "mult", "shift", "zp"]}
            )
        elif l["type"] == "pool":
            entry.update({k: l[k] for k in ["kernel", "stride"]})
        info["layers"].append(entry)
    with open(f"{output_dir}/model_info.json", "w") as f:
        json.dump(info, f, indent=2)

    # Test images
    if test_images is not None:
        img_dir = f"{output_dir}/test_images"
        os.makedirs(img_dir, exist_ok=True)
        n = min(num_test, len(test_images))
        correct = 0
        for i in range(n):
            img = test_images[i]
            label = test_labels[i] if test_labels else -1
            pred, final, _ = int8_infer(img, qparams)
            if pred == label:
                correct += 1
            pf = f"img_{i:04d}"
            _save([f"{int(v) & 0xFF:02x}" for v in img], f"{img_dir}/{pf}.hex")
            # Save final layer output as golden
            last_compute = [
                l["name"] for l in qparams["layers"] if l["type"] in ("conv", "fc")
            ][-1]
            _save(
                [f"{int(v) & 0xFF:02x}" for v in final],
                f"{img_dir}/{pf}_{last_compute}.hex",
            )
            with open(f"{img_dir}/{pf}_label.txt", "w") as f:
                f.write(f"{label}\n")
            with open(f"{img_dir}/{pf}_pred.txt", "w") as f:
                f.write(f"{pred}\n")
            mark = "✓" if pred == label else "✗"
            print(f"  [{i:04d}] label={label}, pred={pred} {mark}")
        print(f"\n  INT8 accuracy: {100.0 * correct / n:.1f}% ({correct}/{n})")

    print(f"\nExported to {output_dir}/")
    return output_dir
