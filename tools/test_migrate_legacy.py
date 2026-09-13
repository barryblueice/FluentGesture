import unittest
from migrate_legacy import convert


class MigrationTests(unittest.TestCase):
    def test_preserves_name_and_scales_coordinates(self):
        result = convert({"向右": [[0, 50], [100, 50]]})
        self.assertEqual(result, {"version": 1, "templates": [
            {"name": "向右", "strokes": [[[0, 0.5], [1, 0.5]]]}]})

    def test_rejects_invalid_libraries(self):
        for library in ([], {"": [[0, 0], [1, 1]]},
                        {"a": [[0, 0], [float("nan"), 0]]},
                        {"a": [[0, 0], [0, 0]]}):
            with self.assertRaises(ValueError):
                convert(library)


if __name__ == "__main__":
    unittest.main()
