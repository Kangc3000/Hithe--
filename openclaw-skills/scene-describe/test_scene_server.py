import base64
import unittest

import scene_server


JPEG_B64 = base64.b64encode(b"\xff\xd8\xfftest-image").decode("ascii")


class SceneServerTests(unittest.TestCase):
    def test_payload_uses_image_input_and_disables_storage(self):
        payload = scene_server.build_openai_payload(
            [JPEG_B64, JPEG_B64], "What color is the car?", "en", "test-model"
        )
        self.assertEqual(payload["model"], "test-model")
        self.assertFalse(payload["store"])
        self.assertEqual(payload["input"][0]["role"], "developer")
        content = payload["input"][1]["content"]
        images = [item for item in content if item["type"] == "input_image"]
        self.assertEqual(len(images), 2)
        self.assertTrue(images[0]["image_url"].startswith("data:image/jpeg;base64,"))
        self.assertEqual(content[0]["text"], "What color is the car?")

    def test_chinese_prompt_requests_traditional_chinese(self):
        self.assertIn("Traditional Chinese", scene_server.description_prompt("zh"))

    def test_extracts_nested_response_text(self):
        response = {
            "output": [
                {"content": [{"type": "output_text", "text": "A doorway is ahead."}]}
            ]
        }
        self.assertEqual(
            scene_server.extract_output_text(response), "A doorway is ahead."
        )

    def test_privacy_interlocks_disable_cloud(self):
        self.assertTrue(scene_server.cloud_is_disabled({"HITHE_CLASSROOM_MODE": "true"}))
        self.assertTrue(
            scene_server.cloud_is_disabled({"HITHE_DISABLE_CLOUD_APIS": "1"})
        )
        self.assertFalse(scene_server.cloud_is_disabled({}))

    def test_rejects_non_jpeg(self):
        with self.assertRaisesRegex(ValueError, "JPEG"):
            scene_server.validate_image(base64.b64encode(b"not-jpeg").decode("ascii"))


if __name__ == "__main__":
    unittest.main()
