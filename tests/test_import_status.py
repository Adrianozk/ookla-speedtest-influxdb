import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('importer', Path(__file__).resolve().parents[1] / 'scripts/import-status-logs.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ImportTests(unittest.TestCase):
    def test_utc_dedup_and_recovery(self):
        fail = '2026-09-24T12:12:16Z level=ERROR event=speedtest_failed detail=[2026-09-24 09:12:16] Couldn\'t resolve host name'
        logs = '\n'.join([
            '2026-09-24T12:12:06Z level=INFO event=speedtest_started server_id=30306',
            fail, fail,
            '2026-09-24T20:02:40.123Z 2026-09-24T20:02:40Z level=INFO event=speedtest_succeeded download_mbps=519',
        ])
        output, counts = module.convert(logs, 'home server,x=y')
        self.assertEqual(counts, {'dns': 1, 'none': 1})
        self.assertIn('host=home\\ server\\,x\\=y', output)
        self.assertIn('server_id="30306"', output)
        self.assertIn(' 1790251936\n', output)
        self.assertNotIn('download_mbps', output)
        self.assertEqual(module.convert(logs, 'host', failures_only=True)[1], {'dns': 1})

    def test_string_escaping_and_unknown_server(self):
        output, _ = module.convert('2026-09-24T12:12:16Z level=ERROR event=speedtest_failed detail=bad "value" \\ path', 'host')
        self.assertIn('error_detail="bad \\"value\\" \\\\ path"', output)
        self.assertIn('server_id="unknown"', output)

    def test_conflicting_results_rejected(self):
        with self.assertRaises(ValueError):
            module.convert('2026-09-24T12:12:16Z level=ERROR event=speedtest_failed detail=bad\n2026-09-24T12:12:16Z level=INFO event=speedtest_succeeded', 'host')


if __name__ == '__main__':
    unittest.main()
