"""One-time delivery and periodic integrity/inference checks; standard library only."""

import hashlib
import json
import os
import shutil
import sys
import urllib.request
from pathlib import Path


def verify(path: Path, manifest: dict):
    if path.stat().st_size != manifest["size_bytes"]:
        raise ValueError("Model size mismatch")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if digest != manifest["sha256"]:
        raise ValueError("Model checksum mismatch")


def deliver(directory: Path, manifest: dict):
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / manifest["filename"]
    if target.exists():
        verify(target, manifest)
        print("Existing model verified; no download needed", flush=True)
        return
    url = (f"https://huggingface.co/{manifest['repository']}/resolve/"
           f"{manifest['revision']}/{manifest['filename']}")
    temporary = target.with_suffix(".part")
    try:
        with urllib.request.urlopen(url, timeout=120) as source, temporary.open("wb") as output:
            shutil.copyfileobj(source, output, length=1024 * 1024)
        verify(temporary, manifest)
        temporary.replace(target)
        print("Model downloaded and SHA-256 verified", flush=True)
    finally:
        temporary.unlink(missing_ok=True)


def evaluate():
    for question in ["Reply with one short greeting.", "What is two plus two? Answer briefly."]:
        body = json.dumps({"model": "qwen-local", "messages": [{"role": "user", "content": question}],
                           "temperature": 0, "max_tokens": 32}).encode()
        request = urllib.request.Request(
            os.getenv("LLM_URL", "http://llm:8080") + "/v1/chat/completions", data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(request, timeout=120) as response:
            result = json.load(response)
        answer = result["choices"][0]["message"]["content"]
        if not isinstance(answer, str) or not answer.strip():
            raise ValueError("Inference smoke check produced no text")
    print(json.dumps({"event": "model_check", "status": "passed", "prompts": 2}), flush=True)


if __name__ == "__main__":
    manifest = json.loads(Path(os.getenv("MODEL_MANIFEST", "/app/model/manifest.json")).read_text())
    directory = Path(os.getenv("MODEL_DIR", "/models"))
    mode = sys.argv[1]
    if mode == "download":
        deliver(directory, manifest)
    elif mode in {"verify", "evaluate"}:
        verify(directory / manifest["filename"], manifest)
        if mode == "evaluate":
            evaluate()
    else:
        raise SystemExit("Usage: python -m jobs.model download|verify|evaluate")

