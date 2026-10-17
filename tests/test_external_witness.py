import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location("witness", pathlib.Path(__file__).with_name("external_witness.py"))
witness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(witness)


class ExternalWitnessChecks(unittest.TestCase):
    def test_scope_rejects_credentials_paths_queries_and_other_hosts(self):
        self.assertEqual(witness.target_host("https://own-test.trycloudflare.com"), "own-test.trycloudflare.com")
        for url in ("http://own-test.trycloudflare.com", "https://own-test.trycloudflare.com.evil.invalid",
                    "https://owner@own-test.trycloudflare.com", "https://own-test.trycloudflare.com:443",
                    "https://own-test.trycloudflare.com/path", "https://own-test.trycloudflare.com/?secret=1",
                    "https://own-test.trycloudflare.com/#secret", "https://127.0.0.1", "https://-bad.trycloudflare.com",
                    "https://own-test.trycloudflare.com\n", "https://own-\ttest.trycloudflare.com"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                witness.target_host(url)

    def test_only_bound_login_redirect_and_actual_cloudflare_1033_count(self):
        host = "own-test.trycloudflare.com"
        login = {"location": "https://login.trycloudflare.com/authorize?hostname=" + host + "&state=redacted"}
        self.assertEqual(witness.classify(host, 302, login, b""), "login-required")
        self.assertEqual(witness.classify("other.trycloudflare.com", 302, login, b""), "unexpected-response")
        error = {"server": "cloudflare", "cf-ray": "a4c1e8667be3ef1e-NRT"}
        self.assertEqual(witness.classify(host, 530, error, b"Error 1033 Cloudflare Tunnel error"), "tunnel-unavailable-1033")
        self.assertEqual(witness.classify(host, 530, error, b"error code: 1033\n"), "tunnel-unavailable-1033")
        for status, headers, body in ((503, error, b"1033 Cloudflare Tunnel"), (530, {}, b"1033 Cloudflare Tunnel"),
                                      (530, error, b"unrelated error"), (404, {}, b"Not found"),
                                      (530, error, b"error code: 1016\n")):
            self.assertEqual(witness.classify(host, status, headers, body), "unexpected-response")

    def test_network_failure_and_transient_outage_cannot_prove_stop(self):
        def rows(pattern):
            return [{"channel": c, "startedAt": i, "classification": kind, "reusedTCP": True, "connectionNumber": 1} for i, kind in enumerate(pattern)
                    for c in ("new", "persistent")]
        login, stopped = "login-required", "tunnel-unavailable-1033"
        self.assertTrue(witness.conclusion(rows([login] * 3 + [stopped] * 4))["externalTransitionObserved"])
        for pattern in ([login] * 7, ["transport-error"] * 7, [login] * 3 + [stopped, login] + [stopped] * 3,
                        [login] * 3 + ["transport-error"] + [stopped] * 3):
            self.assertFalse(witness.conclusion(rows(pattern))["externalTransitionObserved"])
        reconnect = rows([login] * 3 + [stopped] * 3)
        for row in reconnect:
            if row["channel"] == "persistent" and row["classification"] == stopped:
                row.update(reusedTCP=False, connectionNumber=2)
        self.assertFalse(witness.conclusion(reconnect)["externalTransitionObserved"])
        stopped_only = witness.conclusion(rows([stopped] * 3))
        self.assertTrue(stopped_only["externalStoppedStateObserved"])
        self.assertFalse(stopped_only["externalTransitionObserved"])

    def test_key_gate_requires_exact_public_tag_and_never_accepts_email_fallback(self):
        host, tag = "own-test.trycloudflare.com", "a" * 64
        headers = {"server": "cloudflare", "cf-ray": "a4c1e8667be3ef1e-NRT", "x-honeyobs-qa-gate": tag}
        self.assertEqual(witness.classify(host, 401, headers, b"Authentication required", tag), "login-required")
        self.assertEqual(witness.classify(host, 401, headers, b"Authentication required", "b" * 64), "unexpected-response")
        self.assertEqual(witness.classify(host, 401, {}, b"Authentication required", tag), "unexpected-response")
        self.assertEqual(witness.classify(host, 401, headers, b"Authentication required"), "unexpected-response")
        redirect = {"location": "https://login.trycloudflare.com/authorize?hostname=" + host}
        self.assertEqual(witness.classify(host, 302, redirect, b"", tag), "unexpected-response")


if __name__ == "__main__":
    unittest.main()
