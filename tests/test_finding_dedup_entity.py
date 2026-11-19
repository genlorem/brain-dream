"""finding-dedup: пересказ той же дыры про тот же узел (cosine < 0.86) считается дублем."""
import importlib.util
import sys
import types
import unittest
from pathlib import Path

sys.modules.setdefault("semantic", types.SimpleNamespace(MODEL_NAME="m", embed=lambda t: None))
SPEC = importlib.util.spec_from_file_location("fd", Path(__file__).parents[1] / "tools" / "finding-dedup.py")
fd = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fd)

A = "repo:vipzal-admin не связан governed-by с decision:vipzal-workflow"
B = "Узел repo:vipzal-admin без привязки к workflow-решениям"
C = "Playwright клик в Shadow DOM виджета"


class T(unittest.TestCase):
    def test_same_entity_below_global_threshold_is_dup(self):
        self.assertTrue(fd.is_dup(0.70, A, B, 0.86))

    def test_same_entity_too_far_is_new(self):
        self.assertFalse(fd.is_dup(0.40, A, B, 0.86))

    def test_other_entity_needs_global_threshold(self):
        self.assertFalse(fd.is_dup(0.70, A, C, 0.86))
        self.assertTrue(fd.is_dup(0.90, A, C, 0.86))


if __name__ == "__main__":
    unittest.main()
