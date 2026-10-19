"""故障検証の不明な観測を、遮断成功に誤分類しない回帰検査。"""
import unittest
from unittest.mock import MagicMock, patch
from stop_load import probe_denial


class DenialChecks(unittest.TestCase):
    def response(self, value):
        peer = MagicMock()
        peer.__enter__.return_value = peer
        if isinstance(value, Exception):
            peer.recv.side_effect = value
        else:
            peer.recv.return_value = value
        with patch('stop_load.socket.create_connection', return_value=peer):
            return probe_denial(12345, 'test.invalid', '/qa-test')

    def test_eof_is_closed(self):
        self.assertTrue(self.response(b'')['denied'])

    def test_http_is_not_closed(self):
        self.assertFalse(self.response(b'HTTP/1.1 404 Not Found\r\n')['denied'])

    def test_read_timeout_is_unknown(self):
        result = self.response(TimeoutError())
        self.assertFalse(result['denied'])
        self.assertEqual(result['unknown'], 'TimeoutError')

    def test_reset_is_closed(self):
        self.assertTrue(self.response(ConnectionResetError())['denied'])

    def test_connect_errors(self):
        for error, denied in [(TimeoutError(), False), (PermissionError(), False), (ConnectionRefusedError(), True)]:
            with self.subTest(error=type(error).__name__):
                with patch('stop_load.socket.create_connection', side_effect=error):
                    self.assertEqual(probe_denial(12345, 'test.invalid', '/qa-test')['denied'], denied)


if __name__ == '__main__':
    unittest.main()
