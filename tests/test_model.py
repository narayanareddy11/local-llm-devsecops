import hashlib

import pytest

from jobs.model import deliver, verify


def test_integrity_and_idempotent_delivery(tmp_path):
    path = tmp_path / "model.gguf"
    path.write_bytes(b"test fixture, not model weights")
    manifest = {
        "filename": path.name,
        "size_bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }
    verify(path, manifest)
    deliver(tmp_path, manifest)  # Must not access the network.
    path.write_bytes(b"X" * manifest["size_bytes"])
    with pytest.raises(ValueError, match="checksum"):
        verify(path, manifest)


def test_truncated_weights_fail(tmp_path):
    path = tmp_path / "model.gguf"
    path.write_bytes(b"truncated")
    with pytest.raises(ValueError, match="size"):
        verify(path, {"size_bytes": 100})
