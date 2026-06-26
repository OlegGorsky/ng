#!/usr/bin/env python3
"""Generate or edit images through the OpenAI Responses API image_generation tool.

Configuration is intentionally environment-driven so Codex can reuse the script
without rewriting API glue for each image request.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import html
import json
import mimetypes
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from typing import Any

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover - Python <3.11 fallback
    tomllib = None  # type: ignore[assignment]


DEFAULT_OUTPUT = "output/imagegen/generated-image.png"
DEFAULT_MODEL = "gpt-5.4"
CODEX_HOME = pathlib.Path(os.environ.get("CODEX_HOME", pathlib.Path.home() / ".codex")).expanduser()
AUTH_KEY_NAMES = ("CODEX_KEY", "OPENAI_API_KEY", "CODEX_API_KEY")
MAX_IMAGE_BYTES = 50 * 1024 * 1024
SIZE_PRESETS = {
    "square": "1024x1024",
    "wide": "1536x1024",
    "portrait": "1024x1536",
    "hero": "2048x1152",
    "desktop": "1920x1080",
    "mobile": "1080x1920",
    "story": "1080x1920",
    "banner": "1792x1024",
    "avatar": "1024x1024",
}


class ImageGenerationError(RuntimeError):
    pass


@dataclass
class Config:
    api_key: str
    base_url: str
    model: str


@dataclass
class ImageJob:
    prompt: str
    output: str
    action: str = "generate"
    inputs: list[str] | None = None
    file_ids: list[str] | None = None
    data_urls: list[str] | None = None
    mask: str | None = None
    size: str | None = None
    quality: str | None = None
    output_format: str = "png"
    compression: str | None = None
    background: str | None = None
    instructions: str | None = None
    metadata: bool = True
    gallery: bool = False


def env(name: str) -> str | None:
    value = os.environ.get(name)
    return value if value and value.strip() else None


def load_codex_auth_key(preferred_key: str | None = None) -> str | None:
    auth_path = CODEX_HOME / "auth.json"
    if not auth_path.exists():
        return None
    try:
        with auth_path.open("r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception:
        return None

    auth_keys: list[str] = []
    if preferred_key:
        auth_keys.append(preferred_key)
    auth_keys.extend(AUTH_KEY_NAMES)

    for key in dict.fromkeys(auth_keys):
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def load_codex_config() -> dict[str, Any]:
    config_path = CODEX_HOME / "config.toml"
    if not config_path.exists() or tomllib is None:
        return {}
    try:
        with config_path.open("rb") as fh:
            data = tomllib.load(fh)
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def config_value(data: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def selected_provider_config(data: dict[str, Any]) -> dict[str, Any]:
    provider_name = config_value(data, "model_provider", "provider")
    providers = data.get("model_providers")
    if not provider_name or not isinstance(providers, dict):
        return {}
    provider = providers.get(provider_name)
    return provider if isinstance(provider, dict) else {}


def resolve_config() -> Config:
    codex_config = load_codex_config()
    provider_config = selected_provider_config(codex_config)
    provider_env_key = config_value(provider_config, "env_key")
    api_key = (
        (env(provider_env_key) if provider_env_key else None)
        or env("CODEX_KEY")
        or env("OPENAI_API_KEY")
        or env("CODEX_API_KEY")
        or load_codex_auth_key(provider_env_key)
    )
    if not api_key:
        raise ImageGenerationError("API key not found")

    base_url = (
        env("OPENAI_BASE_URL")
        or config_value(provider_config, "base_url", "openai_base_url")
        or config_value(codex_config, "base_url", "openai_base_url")
        or "https://api.openai.com/v1"
    )
    model = (
        env("IMAGE_MODEL")
        or env("OPENAI_MODEL")
        or config_value(provider_config, "model", "openai_model")
        or config_value(codex_config, "model", "openai_model")
        or DEFAULT_MODEL
    )

    if model.startswith("gpt-image-"):
        raise ImageGenerationError(
            "Responses API model must be text-capable; put image options on the image_generation tool"
        )

    return Config(api_key=api_key, base_url=base_url.rstrip("/"), model=model)


def split_paths(raw: str | None) -> list[str]:
    if not raw:
        return []
    separator = ";" if os.name == "nt" else ":"
    return [part for part in raw.split(separator) if part]


def split_csv(raw: str | None) -> list[str]:
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def slugify(text: str, fallback: str = "image") -> str:
    slug = re.sub(r"[^a-zA-Z0-9а-яА-ЯёЁ]+", "-", text.lower()).strip("-")
    slug = slug[:64].strip("-")
    return slug or fallback


def normalize_size(size: str | None) -> str | None:
    if not size:
        return None
    return SIZE_PRESETS.get(size, size)


def output_with_suffix(output: str, suffix: str) -> str:
    path = pathlib.Path(output)
    return str(path.with_name(f"{path.stem}{suffix}{path.suffix}"))


def output_for_prompt(prompt: str, out_dir: str, output_format: str, slug: str | None = None) -> str:
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    name = slugify(slug or prompt)
    return str(pathlib.Path(out_dir) / f"{stamp}-{name}.{output_format}")


def guess_mime(path: pathlib.Path) -> str:
    mime, _ = mimetypes.guess_type(path.name)
    return mime or "image/png"


def sanitize_error(text: str) -> str:
    text = re.sub(r"sk-[A-Za-z0-9_*.-]{8,}", "sk-[redacted]", text)
    text = re.sub(r"Bearer\s+[A-Za-z0-9._~+/=-]+", "Bearer [redacted]", text, flags=re.IGNORECASE)
    return text


def image_data_url(path: str) -> str:
    image_path = pathlib.Path(path).expanduser()
    if not image_path.exists():
        raise ImageGenerationError(f"Input image not found: {path}")
    if image_path.stat().st_size >= MAX_IMAGE_BYTES:
        raise ImageGenerationError(f"Input image must be under 50MB: {path}")
    encoded = base64.b64encode(image_path.read_bytes()).decode("ascii")
    return f"data:{guess_mime(image_path)};base64,{encoded}"


def request_json(config: Config, method: str, url: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Authorization": f"Bearer {config.api_key}"}
    if payload is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            body = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise ImageGenerationError(f"HTTP {exc.code}: {sanitize_error(body)}") from exc
    except urllib.error.URLError as exc:
        raise ImageGenerationError(f"Network error: {exc.reason}") from exc

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError as exc:
        events = parse_sse_events(body)
        if events:
            return {"events": events}
        raise ImageGenerationError("API returned non-JSON response") from exc
    if not isinstance(parsed, dict):
        raise ImageGenerationError("API returned unexpected JSON shape")
    return parsed


def parse_sse_events(body: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for block in body.split("\n\n"):
        data_lines: list[str] = []
        for raw_line in block.splitlines():
            line = raw_line.strip()
            if line.startswith("data:"):
                data_lines.append(line[5:].strip())
        if not data_lines:
            continue
        data = "\n".join(data_lines)
        if data == "[DONE]":
            continue
        try:
            parsed = json.loads(data)
        except json.JSONDecodeError:
            continue
        if isinstance(parsed, dict):
            events.append(parsed)
    return events


def multipart_upload(config: Config, path: str, purpose: str = "vision") -> str:
    file_path = pathlib.Path(path).expanduser()
    if not file_path.exists():
        raise ImageGenerationError(f"Upload file not found: {path}")
    if file_path.stat().st_size >= MAX_IMAGE_BYTES:
        raise ImageGenerationError(f"Upload file must be under 50MB: {path}")

    boundary = f"----codex-{uuid.uuid4().hex}"
    chunks: list[bytes] = []

    def add_field(name: str, value: str) -> None:
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode(),
                value.encode(),
                b"\r\n",
            ]
        )

    def add_file(name: str, upload_path: pathlib.Path) -> None:
        chunks.extend(
            [
                f"--{boundary}\r\n".encode(),
                (
                    f'Content-Disposition: form-data; name="{name}"; '
                    f'filename="{upload_path.name}"\r\n'
                ).encode(),
                f"Content-Type: {guess_mime(upload_path)}\r\n\r\n".encode(),
                upload_path.read_bytes(),
                b"\r\n",
            ]
        )

    add_field("purpose", purpose)
    add_file("file", file_path)
    chunks.append(f"--{boundary}--\r\n".encode())
    body = b"".join(chunks)

    request = urllib.request.Request(
        f"{config.base_url}/files",
        data=body,
        headers={
            "Authorization": f"Bearer {config.api_key}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            data = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body_text = exc.read().decode("utf-8", errors="replace")
        raise ImageGenerationError(f"File upload HTTP {exc.code}: {sanitize_error(body_text)}") from exc
    except urllib.error.URLError as exc:
        raise ImageGenerationError(f"File upload network error: {exc.reason}") from exc

    file_id = data.get("id")
    if not isinstance(file_id, str) or not file_id:
        raise ImageGenerationError("File upload did not return a file id")
    return file_id


def build_tool(job: ImageJob, mask_file_id: str | None = None) -> dict[str, Any]:
    tool: dict[str, Any] = {"type": "image_generation"}

    tool["action"] = job.action
    if job.size:
        tool["size"] = normalize_size(job.size)
    if job.quality:
        tool["quality"] = job.quality
    if job.output_format:
        tool["output_format"] = job.output_format
    if job.compression:
        try:
            tool["output_compression"] = int(job.compression)
        except ValueError as exc:
            raise ImageGenerationError("Compression must be an integer") from exc
    if job.background:
        tool["background"] = job.background

    if mask_file_id:
        tool["input_image_mask"] = {"file_id": mask_file_id}

    return tool


def build_content(config: Config, job: ImageJob) -> tuple[list[dict[str, Any]], str | None]:
    if not job.prompt:
        raise ImageGenerationError("IMAGE_PROMPT is required")

    input_paths = job.inputs or []
    file_ids = job.file_ids or []
    data_urls = job.data_urls or []

    if job.action == "edit" and not (input_paths or file_ids or data_urls):
        raise ImageGenerationError("IMAGE_ACTION=edit requires IMAGE_INPUTS, IMAGE_FILE_IDS, or IMAGE_DATA_URLS")

    mask_file_id = None
    content: list[dict[str, Any]] = [{"type": "input_text", "text": job.prompt}]

    if job.mask:
        if not input_paths and not file_ids:
            raise ImageGenerationError("Mask edits require an input image path or existing file id")
        if input_paths:
            first_id = multipart_upload(config, input_paths[0])
            content.append({"type": "input_image", "file_id": first_id})
            for path in input_paths[1:]:
                content.append({"type": "input_image", "image_url": image_data_url(path)})
        for file_id in file_ids:
            content.append({"type": "input_image", "file_id": file_id})
        mask_file_id = multipart_upload(config, job.mask)
    else:
        for path in input_paths:
            content.append({"type": "input_image", "image_url": image_data_url(path)})
        for file_id in file_ids:
            content.append({"type": "input_image", "file_id": file_id})

    for data_url in data_urls:
        content.append({"type": "input_image", "image_url": data_url})

    return content, mask_file_id


def find_images(value: Any) -> list[str]:
    images: list[str] = []
    if isinstance(value, dict):
        item_type = value.get("type")
        result = value.get("result")
        if item_type == "image_generation_call" and isinstance(result, str) and result:
            images.append(result)
        partial = value.get("partial_image_b64")
        if item_type == "response.image_generation_call.partial_image" and isinstance(partial, str) and partial:
            images.append(partial)
        for nested in value.values():
            images.extend(find_images(nested))
    elif isinstance(value, list):
        for item in value:
            images.extend(find_images(item))
    return images


def save_image(encoded: str, output_path: str) -> pathlib.Path:
    if encoded.startswith("data:"):
        encoded = encoded.split(",", 1)[1]
    try:
        raw = base64.b64decode(encoded, validate=False)
    except Exception as exc:
        raise ImageGenerationError("Image result was not valid base64") from exc

    path = pathlib.Path(output_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)
    return path


def write_metadata(path: pathlib.Path, job: ImageJob, config: Config, response: dict[str, Any]) -> pathlib.Path:
    metadata_path = path.with_suffix(path.suffix + ".json")
    metadata = {
        "created_at": dt.datetime.now(dt.UTC).isoformat(),
        "prompt": job.prompt,
        "action": job.action,
        "size": normalize_size(job.size),
        "quality": job.quality,
        "output_format": job.output_format,
        "background": job.background,
        "inputs": job.inputs or [],
        "mask": job.mask,
        "model": config.model,
        "base_url": config.base_url,
        "response_id": response.get("id"),
    }
    metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return metadata_path


def write_gallery(paths: list[pathlib.Path], gallery_path: str = "output/imagegen/gallery.html") -> pathlib.Path:
    gallery = pathlib.Path(gallery_path)
    gallery.parent.mkdir(parents=True, exist_ok=True)
    items = []
    for path in paths:
        rel = os.path.relpath(path, gallery.parent)
        caption = html.escape(str(path))
        items.append(
            f'<figure><img src="{html.escape(rel)}" alt="{caption}"><figcaption>{caption}</figcaption></figure>'
        )
    body = "\n".join(items)
    gallery.write_text(
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "<title>Image generation gallery</title>"
        "<style>body{font-family:system-ui,sans-serif;margin:24px;background:#111;color:#eee}"
        ".grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(280px,1fr));gap:18px}"
        "figure{margin:0;background:#1b1b1b;padding:10px;border-radius:8px}"
        "img{width:100%;height:auto;display:block;border-radius:4px}"
        "figcaption{font-size:12px;color:#bbb;margin-top:8px;word-break:break-all}</style></head>"
        f"<body><main class='grid'>{body}</main></body></html>\n",
        encoding="utf-8",
    )
    return gallery


def request_image(config: Config, job: ImageJob) -> pathlib.Path:
    content, mask_file_id = build_content(config, job)
    tool = build_tool(job, mask_file_id)

    payload = {
        "model": config.model,
        "store": False,
        "stream": True,
        "instructions": job.instructions
        or "Generate or edit the requested image using the image_generation tool. Return the image result.",
        "input": [{"role": "user", "content": content}],
        "tools": [tool],
    }

    response = request_json(config, "POST", f"{config.base_url}/responses", payload)
    images = find_images(response)
    if not images:
        response_id = response.get("id", "<no id>")
        raise ImageGenerationError(f"No image_generation result found in response {response_id}")

    saved_path = save_image(images[-1], job.output)
    if job.metadata:
        write_metadata(saved_path, job, config, response)
    return saved_path


def env_job() -> ImageJob:
    has_inputs = bool(split_paths(env("IMAGE_INPUTS")) or split_csv(env("IMAGE_FILE_IDS")) or split_csv(env("IMAGE_DATA_URLS")))
    action = env("IMAGE_ACTION") or ("edit" if has_inputs else "generate")
    prompt = env("IMAGE_PROMPT")
    if not prompt:
        raise ImageGenerationError("IMAGE_PROMPT is required")
    return ImageJob(
        prompt=prompt,
        output=env("IMAGE_OUTPUT") or DEFAULT_OUTPUT,
        action=action,
        inputs=split_paths(env("IMAGE_INPUTS")),
        file_ids=split_csv(env("IMAGE_FILE_IDS")),
        data_urls=split_csv(env("IMAGE_DATA_URLS")),
        mask=env("IMAGE_MASK"),
        size=env("IMAGE_SIZE"),
        quality=env("IMAGE_QUALITY"),
        output_format=env("IMAGE_FORMAT") or "png",
        compression=env("IMAGE_COMPRESSION"),
        background=env("IMAGE_BACKGROUND"),
        instructions=env("IMAGE_INSTRUCTIONS"),
        metadata=env("IMAGE_METADATA") != "false",
        gallery=env("IMAGE_GALLERY") == "true",
    )


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("-o", "--output", help="Output image path")
    parser.add_argument("--out-dir", default="output/imagegen", help="Output directory for generated names")
    parser.add_argument("--slug", help="Filename slug when --output is omitted")
    parser.add_argument("--size", help=f"Size or preset: {', '.join(sorted(SIZE_PRESETS))}")
    parser.add_argument("--quality", choices=["low", "medium", "high", "auto"], help="Image quality")
    parser.add_argument("--format", default="png", choices=["png", "jpeg", "webp"], help="Output format")
    parser.add_argument("--compression", help="Output compression when supported")
    parser.add_argument("--background", help="Background option when supported")
    parser.add_argument("--instructions", help="Responses instructions field")
    parser.add_argument("--no-metadata", action="store_true", help="Do not write sidecar .json metadata")
    parser.add_argument("--gallery", action="store_true", help="Write/update output/imagegen/gallery.html")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description="Generate or edit images through the Responses API image_generation tool")
    subparsers = root.add_subparsers(dest="command")

    generate = subparsers.add_parser("generate", help="Generate one or more images")
    generate.add_argument("prompt", nargs="?", help="Image prompt")
    generate.add_argument("--prompt", dest="prompt_option", help="Image prompt")
    generate.add_argument("--variants", type=int, default=1, help="Number of variants to generate")
    add_common_args(generate)

    edit = subparsers.add_parser("edit", help="Edit an image")
    edit.add_argument("prompt", nargs="?", help="Edit prompt")
    edit.add_argument("--prompt", dest="prompt_option", help="Edit prompt")
    edit.add_argument("-i", "--input", action="append", default=[], help="Input image path; can be repeated")
    edit.add_argument("--file-id", action="append", default=[], help="Existing OpenAI file id; can be repeated")
    edit.add_argument("--data-url", action="append", default=[], help="Input image data URL; can be repeated")
    edit.add_argument("--mask", help="Mask path for masked edit")
    add_common_args(edit)

    batch = subparsers.add_parser("batch", help="Generate/edit jobs from JSONL")
    batch.add_argument("--input", required=True, help="JSONL file with image jobs")
    batch.add_argument("--out-dir", default="output/imagegen/batch", help="Default output directory")
    batch.add_argument("--gallery", action="store_true", help="Write gallery for batch outputs")
    batch.add_argument("--no-metadata", action="store_true", help="Do not write sidecar .json metadata")

    root.add_argument("--list-presets", action="store_true", help="Print size presets and exit")
    return root


def job_from_args(args: argparse.Namespace, action: str) -> ImageJob:
    prompt = args.prompt_option or args.prompt or env("IMAGE_PROMPT")
    if not prompt:
        raise ImageGenerationError("Prompt is required")
    output_format = args.format
    output = args.output or output_for_prompt(prompt, args.out_dir, output_format, args.slug)
    return ImageJob(
        prompt=prompt,
        output=output,
        action=action,
        inputs=getattr(args, "input", []) or [],
        file_ids=getattr(args, "file_id", []) or [],
        data_urls=getattr(args, "data_url", []) or [],
        mask=getattr(args, "mask", None),
        size=args.size,
        quality=args.quality,
        output_format=output_format,
        compression=args.compression,
        background=args.background,
        instructions=args.instructions,
        metadata=not args.no_metadata,
        gallery=args.gallery,
    )


def jobs_from_jsonl(path: str, out_dir: str, metadata: bool) -> list[ImageJob]:
    jobs: list[ImageJob] = []
    jsonl = pathlib.Path(path).expanduser()
    if not jsonl.exists():
        raise ImageGenerationError(f"Batch input not found: {path}")
    for line_number, line in enumerate(jsonl.read_text(encoding="utf-8").splitlines(), start=1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ImageGenerationError(f"Invalid JSON on line {line_number}: {exc}") from exc
        if not isinstance(data, dict):
            raise ImageGenerationError(f"Batch line {line_number} must be a JSON object")
        prompt = data.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            raise ImageGenerationError(f"Batch line {line_number} is missing prompt")
        output_format = str(data.get("format") or data.get("output_format") or "png")
        output = str(
            data.get("output")
            or data.get("out")
            or output_for_prompt(prompt, out_dir, output_format, data.get("slug"))
        )
        action = str(data.get("action") or ("edit" if data.get("inputs") or data.get("input") else "generate"))
        inputs = data.get("inputs") or data.get("input") or []
        if isinstance(inputs, str):
            inputs = [inputs]
        jobs.append(
            ImageJob(
                prompt=prompt,
                output=output,
                action=action,
                inputs=list(inputs),
                file_ids=list(data.get("file_ids") or []),
                data_urls=list(data.get("data_urls") or []),
                mask=data.get("mask"),
                size=data.get("size"),
                quality=data.get("quality"),
                output_format=output_format,
                compression=data.get("compression"),
                background=data.get("background"),
                instructions=data.get("instructions"),
                metadata=metadata and data.get("metadata", True) is not False,
                gallery=False,
            )
        )
    return jobs


def run_cli(argv: list[str]) -> int:
    args = parser().parse_args(argv)
    if args.list_presets:
        for name, size in sorted(SIZE_PRESETS.items()):
            print(f"{name}\t{size}")
        return 0

    config = resolve_config()
    saved: list[pathlib.Path] = []

    if args.command == "batch":
        for job in jobs_from_jsonl(args.input, args.out_dir, not args.no_metadata):
            path = request_image(config, job)
            saved.append(path)
            print(str(path))
        if args.gallery and saved:
            print(str(write_gallery(saved)))
        return 0

    if args.command == "edit":
        job = job_from_args(args, "edit")
        saved.append(request_image(config, job))
    elif args.command == "generate":
        base_job = job_from_args(args, "generate")
        variants = max(1, args.variants)
        for index in range(variants):
            job = ImageJob(**base_job.__dict__)
            if variants > 1:
                job.output = output_with_suffix(base_job.output, f"-v{index + 1:02d}")
            saved.append(request_image(config, job))
    else:
        job = env_job()
        saved.append(request_image(config, job))

    if saved and (getattr(args, "gallery", False) or (args.command is None and env("IMAGE_GALLERY") == "true")):
        print(str(write_gallery(saved)))
    for path in saved:
        print(str(path))
    return 0


def main() -> int:
    try:
        return run_cli(sys.argv[1:])
    except ImageGenerationError as exc:
        print(str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
