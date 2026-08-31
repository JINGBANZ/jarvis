"""Convert upstream Silero VAD (16 kHz path) to a compiled Core ML model for JarvisApp.

Driven by scripts/build-vad.sh, which pins every input. Emits `SileroVAD.mlmodelc` and refuses to
write it unless the converted model matches upstream ONNX Runtime on a streaming parity run. The
converted artifact is committed, so this check is the only thing standing between a silent numerical
regression and production.

Streaming contract (upstream `OnnxWrapper`, 16 kHz): 512-sample chunks, each prefixed with the
trailing 64 samples of the previous window, LSTM state (2, 1, 128) threaded call to call.
"""
import argparse
import shutil
import sys
from pathlib import Path

import numpy as np
import torch
import coremltools as ct
import onnxruntime as ort

CHUNK, CONTEXT = 512, 64
WINDOW = CHUNK + CONTEXT
STATE_SHAPE = (2, 1, 128)
SAMPLE_RATE = 16_000
PARITY_TOLERANCE = 1e-3


class Silero16k(torch.nn.Module):
    """16 kHz-only, fixed-shape wrapper around the packaged model's submodules.

    Three things in the packaged TorchScript have no Core ML lowering, all of them scaffolding rather
    than math, so this wrapper routes around each:

    * `VADRNNJIT.decoder` guards its LSTM call with `if bool(torch.len(state))` to support an omitted
      state. We always thread state explicitly, so the branch is dead, but `aten::len` still fails
      conversion. Calling the submodules directly skips it.
    * The scripted `LSTMCell` carries torch's shape-validation branches (`aten::__contains__`), and an
      eager `nn.LSTMCell` lowers through `aten::unsafe_chunk`. Writing the cell out as matmuls plus
      slicing expresses identical math in fully lowerable ops.
    * The STFT reads `hop_length` as a module attribute; tracing a *scripted* submodule leaves that as
      a `prim::GetAttr` that coremltools cannot constant-fold (it surfaces as a conv stride typed
      `tensor[1,str]`). `torch.jit.freeze` below inlines it.

    `assert_matches_packaged_model` proves the routing is numerically faithful.
    """

    def __init__(self, inner: torch.nn.Module) -> None:
        super().__init__()
        self.stft = inner.stft
        self.encoder = inner.encoder
        self.dec = inner.decoder.decoder
        source = inner.decoder.rnn
        self.hidden_size = source.weight_hh.shape[1]
        for name in ("weight_ih", "weight_hh", "bias_ih", "bias_hh"):
            self.register_buffer(name, getattr(source, name).detach().clone())

    def forward(self, audio_input, state_in):
        x = self.encoder(self.stft(audio_input)).squeeze(-1)

        h_prev, c_prev = state_in[0], state_in[1]
        gates = (torch.matmul(x, self.weight_ih.t()) + self.bias_ih
                 + torch.matmul(h_prev, self.weight_hh.t()) + self.bias_hh)
        n = self.hidden_size
        i = torch.sigmoid(gates[:, 0:n])            # PyTorch gate order: i, f, g, o
        f = torch.sigmoid(gates[:, n:2 * n])
        g = torch.tanh(gates[:, 2 * n:3 * n])
        o = torch.sigmoid(gates[:, 3 * n:4 * n])
        c = f * c_prev + i * g
        h = o * torch.tanh(c)

        y = self.dec(h.unsqueeze(-1).to(torch.float32))
        prob = y.squeeze(1).mean(dim=1).unsqueeze(1)
        return prob, torch.stack([h, c])


def assert_matches_packaged_model(wrapper: torch.nn.Module, inner: torch.nn.Module) -> float:
    """The wrapper must reproduce the packaged module before anything is converted."""
    rng = np.random.default_rng(1)
    state_a = torch.zeros(*STATE_SHAPE)
    state_b = torch.zeros(*STATE_SHAPE)
    worst = 0.0
    with torch.no_grad():
        for _ in range(32):
            x = torch.from_numpy(rng.standard_normal((1, WINDOW)).astype(np.float32)) * 0.3
            packaged, state_a = inner(x, state_a)
            routed, state_b = wrapper(x, state_b)
            worst = max(worst, float((packaged - routed).abs().max()))
    if worst > 1e-5:
        sys.exit(f"wrapper diverges from the packaged model (max |delta| = {worst:.3e})")
    return worst


def convert(wrapper: torch.nn.Module) -> ct.models.MLModel:
    with torch.no_grad():
        traced = torch.jit.trace(
            wrapper, (torch.zeros(1, WINDOW), torch.zeros(*STATE_SHAPE)), check_trace=False)
    traced = torch.jit.freeze(traced.eval())
    return ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="audio_input", shape=(1, WINDOW), dtype=np.float32),
            ct.TensorType(name="state_in", shape=STATE_SHAPE, dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="prob", dtype=np.float32),
            ct.TensorType(name="state_out", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.macOS14,
        # float32 throughout: the endpointer compares against fixed thresholds, so drifting the
        # probability to save a few hundred KB would silently move every turn boundary.
        compute_precision=ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        convert_to="mlprogram",
    )


def parity_against_onnx(mlmodel: ct.models.MLModel, onnx_path: Path) -> float:
    """Stream the same signal through both runtimes and return the worst probability delta."""
    session = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
    takes_sample_rate = any(i.name == "sr" for i in session.get_inputs())

    rng = np.random.default_rng(7)
    span = CHUNK * 24
    signal = np.concatenate([
        np.zeros(span, dtype=np.float32),
        (rng.standard_normal(span) * 0.05).astype(np.float32),
        (0.4 * np.sin(2 * np.pi * 220 * np.arange(span) / SAMPLE_RATE)).astype(np.float32),
        (rng.standard_normal(span) * 0.4).astype(np.float32),
    ])

    ml_state = np.zeros(STATE_SHAPE, dtype=np.float32)
    onnx_state = np.zeros(STATE_SHAPE, dtype=np.float32)
    ml_context = np.zeros(CONTEXT, dtype=np.float32)
    onnx_context = np.zeros(CONTEXT, dtype=np.float32)
    worst = 0.0
    for index in range(len(signal) // CHUNK):
        chunk = signal[index * CHUNK:(index + 1) * CHUNK]
        ml_window = np.concatenate([ml_context, chunk])[None, :].astype(np.float32)
        onnx_window = np.concatenate([onnx_context, chunk])[None, :].astype(np.float32)

        out = mlmodel.predict({"audio_input": ml_window, "state_in": ml_state})
        ml_prob = float(np.array(out["prob"]).reshape(-1)[0])
        ml_state = np.array(out["state_out"], dtype=np.float32).reshape(STATE_SHAPE)

        feed = {"input": onnx_window, "state": onnx_state}
        if takes_sample_rate:
            feed["sr"] = np.array(SAMPLE_RATE, dtype=np.int64)
        onnx_prob, onnx_state = session.run(None, feed)
        onnx_prob = float(np.array(onnx_prob).reshape(-1)[0])

        ml_context = ml_window[0, -CONTEXT:]
        onnx_context = onnx_window[0, -CONTEXT:]
        worst = max(worst, abs(ml_prob - onnx_prob))
    return worst


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--silero-data", required=True, type=Path,
                        help="silero-vad src/silero_vad/data directory at the pinned revision")
    parser.add_argument("--output", required=True, type=Path,
                        help="destination .mlmodelc (replaced atomically on success)")
    args = parser.parse_args()

    jit_path = args.silero_data / "silero_vad.jit"
    onnx_path = args.silero_data / "silero_vad_16k_op15.onnx"
    for path in (jit_path, onnx_path):
        if not path.exists():
            sys.exit(f"missing upstream artifact: {path}")

    packaged = torch.jit.load(str(jit_path))
    packaged.eval()
    inner = packaged._model                     # the 16 kHz model; _model_8k is unused
    wrapper = Silero16k(inner).eval()

    routing_delta = assert_matches_packaged_model(wrapper, inner)
    print(f"wrapper vs packaged module: max |delta| = {routing_delta:.3e}")

    mlmodel = convert(wrapper)

    parity_delta = parity_against_onnx(mlmodel, onnx_path)
    print(f"core ml vs onnx runtime:    max |delta| = {parity_delta:.3e} "
          f"(tolerance {PARITY_TOLERANCE:.0e})")
    if parity_delta > PARITY_TOLERANCE:
        sys.exit("parity check failed, refusing to write the model")

    compiled = Path(mlmodel.get_compiled_model_path())
    if args.output.exists():
        shutil.rmtree(args.output)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(compiled, args.output)

    # coremltools writes an analytics blob that differs run to run. The model loads and scores
    # identically without it, and keeping it would make every regeneration show a spurious diff on a
    # committed artifact whose whole point is being reproducible.
    analytics = args.output / "analytics"
    if analytics.exists():
        shutil.rmtree(analytics)
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
