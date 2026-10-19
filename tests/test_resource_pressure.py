"""負荷試験が中止すべき境界と、warningを試験可能とする境界を固定する。"""
import unittest
from resource_pressure import over_budget


class BudgetChecks(unittest.TestCase):
    def test_levels(self):
        for level, expected in [(1, False), (2, False), (4, True), (0, True), (8, True)]:
            with self.subTest(level=level):
                self.assertEqual(over_budget({'level': level, 'freePercent': 30, 'swapMiB': 700}, 700), expected)

    def test_free_memory_boundary(self):
        for free, expected in [(12, False), (11, True)]:
            self.assertEqual(over_budget({'level': 1, 'freePercent': free, 'swapMiB': 700}, 700), expected)

    def test_swap_is_cumulative_from_suite_baseline(self):
        for swap, expected in [(1212, False), (1212.01, True)]:
            self.assertEqual(over_budget({'level': 2, 'freePercent': 30, 'swapMiB': swap}, 700), expected)


if __name__ == '__main__':
    unittest.main()
