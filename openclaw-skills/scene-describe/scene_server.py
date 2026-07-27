#!/usr/bin/env python3
"""Local, privacy-conscious scene-description relay for Hithe."""

import argparse
import base64
import json
import os
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"
DEFAULT_MODEL = "gpt-5.6-sol"
MAX_REQUEST_BYTES = 12 * 1024 * 1024


def is_truthy(value):
    return str(value or "").strip().lower() in {"1", "true", "yes", "on"}


def cloud_is_disabled(environment=None):
    environment = environment or os.environ
    return is_truthy(environment.get("HITHE_CLASSROOM_MODE")) or is_truthy(
        environment.get("HITHE_DISABLE_CLOUD_APIS")
    )


def description_prompt(language):
    language_instruction = (
        "Answer in Traditional Chinese." if language == "zh" else "Answer in English."
    )
    return (
        "Answer the user's visual question using the ordered first-person video frames. "
        "Use one to three short sentences suitable for spoken playback to a blind or "
        "low-vision user. Treat counts as visible estimates and state uncertainty plainly. "
        "Use earlier frames when the user asks about something that just passed or moved. "
        "Do not identify people, infer sensitive traits, or claim that a route or traffic "
        f"crossing is safe. {language_instruction}"
    )


def build_openai_payload(image_b64s, question, language, model):
    image_content = []
    for index, image_b64 in enumerate(image_b64s):
        if index == 0:
            position = "oldest"
        elif index == len(image_b64s) - 1:
            position = "newest"
        else:
            position = str(index + 1)
        image_content.extend(
            [
                {"type": "input_text", "text": "Video frame %s:" % position},
                {
                    "type": "input_image",
                    "image_url": "data:image/jpeg;base64," + image_b64,
                    "detail": "low",
                },
            ]
        )
    return {
        "model": model,
        "store": False,
        "reasoning": {"effort": "low"},
        "max_output_tokens": 220,
        "input": [
            {
                "role": "developer",
                "content": [{"type": "input_text", "text": description_prompt(language)}],
            },
            {
                "role": "user",
                "content": [{"type": "input_text", "text": question}] + image_content,
            },
        ],
    }


def extract_output_text(response):
    direct = response.get("output_text")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()

    text_parts = []
    for item in response.get("output", []):
        for content in item.get("content", []):
            if content.get("type") == "output_text" and content.get("text"):
                text_parts.append(content["text"].strip())
    if text_parts:
        return "\n".join(text_parts)
    raise ValueError("OpenAI returned no scene description")


def validate_image(image_b64):
    if not isinstance(image_b64, str) or not image_b64:
        raise ValueError("image_b64 is required")
    try:
        image_data = base64.b64decode(image_b64, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("image_b64 is not valid base64") from error
    if not image_data.startswith(b"\xff\xd8\xff"):
        raise ValueError("image_b64 must contain a JPEG image")
    return image_data


def call_openai(image_b64s, question, language, model, api_key, timeout=60):
    payload = build_openai_payload(image_b64s, question, language, model)
    request = urllib.request.Request(
        OPENAI_RESPONSES_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": "Bearer " + api_key,
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        try:
            message = json.loads(detail).get("error", {}).get("message", detail)
        except json.JSONDecodeError:
            message = detail
        raise RuntimeError("OpenAI request failed: " + str(message)) from error
    except urllib.error.URLError as error:
        raise RuntimeError("Could not reach OpenAI: " + str(error.reason)) from error
    return extract_output_text(result)


class SceneDescriptionHandler(BaseHTTPRequestHandler):
    server_version = "HitheSceneRelay/1.0"

    def log_message(self, format_string, *args):
        # Log request metadata only. Image and description content are never logged.
        print("%s - %s" % (self.address_string(), format_string % args))

    def send_json(self, status, value):
        encoded = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self):
        if self.path != "/health":
            self.send_json(404, {"error": "Not found"})
            return
        configured = bool(os.environ.get("OPENAI_API_KEY"))
        self.send_json(
            200,
            {
                "status": "ok",
                "configured": configured,
                "cloud_disabled": cloud_is_disabled(),
                "model": self.server.model,
            },
        )

    def do_POST(self):
        if self.path != "/describe":
            self.send_json(404, {"error": "Not found"})
            return
        if cloud_is_disabled():
            self.send_json(403, {"error": "Cloud description is disabled by privacy settings"})
            return

        api_key = os.environ.get("OPENAI_API_KEY")
        if not api_key:
            self.send_json(503, {"error": "The Mac relay needs an OPENAI_API_KEY"})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
            if content_length <= 0 or content_length > MAX_REQUEST_BYTES:
                raise ValueError("Request is empty or too large")
            body = json.loads(self.rfile.read(content_length).decode("utf-8"))
            image_b64s = body.get("image_b64s")
            if image_b64s is None and body.get("image_b64"):
                image_b64s = [body["image_b64"]]
            if not isinstance(image_b64s, list) or not 1 <= len(image_b64s) <= 8:
                raise ValueError("image_b64s must contain between 1 and 8 JPEG frames")
            for image_b64 in image_b64s:
                validate_image(image_b64)
            question = str(
                body.get("question") or "Describe what is around me right now."
            ).strip()
            if not question or len(question) > 500:
                raise ValueError("question must contain between 1 and 500 characters")
            language = body.get("language", "en")
            if language not in {"en", "zh"}:
                raise ValueError("language must be en or zh")

            started = time.monotonic()
            description = call_openai(
                image_b64s=image_b64s,
                question=question,
                language=language,
                model=self.server.model,
                api_key=api_key,
            )
            self.send_json(
                200,
                {
                    "description": description,
                    "language": language,
                    "model": self.server.model,
                    "latency_ms": round((time.monotonic() - started) * 1000),
                },
            )
        except (ValueError, json.JSONDecodeError) as error:
            self.send_json(400, {"error": str(error)})
        except RuntimeError as error:
            self.send_json(502, {"error": str(error)})
        except Exception as error:
            print("Unexpected scene-description error: " + repr(error))
            self.send_json(500, {"error": "Unexpected relay error"})


def parse_args():
    parser = argparse.ArgumentParser(description="Run the Hithe scene-description relay")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument(
        "--model", default=os.environ.get("OPENAI_VISION_MODEL", DEFAULT_MODEL)
    )
    return parser.parse_args()


def main():
    args = parse_args()
    server = ThreadingHTTPServer((args.host, args.port), SceneDescriptionHandler)
    server.model = args.model
    print("Hithe scene relay listening on http://%s:%s" % (args.host, args.port))
    print("Model: %s" % args.model)
    if not os.environ.get("OPENAI_API_KEY"):
        print("OPENAI_API_KEY is not set; /describe will explain how to configure it.")
    server.serve_forever()


if __name__ == "__main__":
    main()
