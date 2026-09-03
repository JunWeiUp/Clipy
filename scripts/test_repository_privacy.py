#!/usr/bin/env python3
"""Regression checks for public examples and accidentally tracked personal data."""

import unittest

from check_repository import check_path, check_text


class RepositoryPrivacyTests(unittest.TestCase):
    snippet_path = 'clipy_macos/Sources/Snippets/SnippetManager.swift'

    def test_personal_exports_and_databases_are_rejected(self):
        for path in (
            'snippets.json', 'backup/history.json', 'exports/notifications.json',
            'cache/history.db', 'cache/history.db-wal', 'cache/history.db-shm',
            'cache/history.sqlite', 'cache/history.sqlite3',
            'cache/history.sqlite3-wal', 'cache/history.sqlite-shm',
            'res/search.png', 'clipy_android/android/key.properties',
        ):
            with self.subTest(path=path):
                self.assertIsNotNone(check_path(path))

    def test_public_source_and_examples_remain_allowed(self):
        for path in ('README.md', '.env.example', 'Logo.png', self.snippet_path):
            with self.subTest(path=path):
                self.assertIsNone(check_path(path))

    def test_snippet_emails_use_reserved_domains(self):
        for domain in ('example.com', 'example.org', 'example.net', 'mail.example'):
            with self.subTest(domain=domain):
                self.assertIsNone(check_text(self.snippet_path, f'hello@{domain}'.encode()))
        self.assertIsNotNone(check_text(self.snippet_path, b'hello@invalid.test'))
        self.assertIsNotNone(check_text(self.snippet_path, b'hello@example.com.invalid.test'))

    def test_finding_does_not_echo_credentials(self):
        token = b'ghp_' + b'a' * 40
        finding = check_text('config.txt', token)
        self.assertEqual(finding, 'possible credential')
        self.assertNotIn(token.decode(), finding)

    def test_image_scale_names_are_not_treated_as_snippet_emails(self):
        self.assertIsNone(check_text('assets/Contents.json', b'"icon@2x.png"'))


if __name__ == '__main__':
    unittest.main()
