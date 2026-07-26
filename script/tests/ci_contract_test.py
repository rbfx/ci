#!/usr/bin/env python3

import pathlib
import re
import sys
import unittest
from contextlib import redirect_stdout
from io import BytesIO, StringIO
from unittest.mock import patch


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(REPO_ROOT / 'script'))

import ci_prepare_matrix as matrix  # noqa: E402
import ci_data  # noqa: E402


def yaml_section_keys(path: pathlib.Path, section: str) -> set[str]:
    lines = path.read_text(encoding='utf-8').splitlines()
    start = lines.index(f'{section}:') + 1
    keys: set[str] = set()
    for line in lines[start:]:
        if line and not line.startswith(' '):
            break
        match = re.match(r'^  ([A-Za-z_][A-Za-z0-9_]*):\s*$', line)
        if match:
            keys.add(match.group(1))
    return keys


class MatrixContractTest(unittest.TestCase):
    def test_standard_matrix_has_twenty_grouped_targets(self) -> None:
        build_types = matrix.parse_build_types(matrix.DEFAULT_BUILD_TYPES)
        entries = matrix.resolve_matrix_selection('platforms', ['all'], build_types)
        grouped = matrix.build_platform_matrix(entries, ['all'])['include']

        self.assertEqual(20, len(grouped))
        self.assertEqual(matrix.ALL_PLATFORM_TAGS, [
            row['ci_platform_tag'] for row in grouped
        ])
        self.assertTrue(all(len(row['ci_build_types']) == 2 for row in grouped))

    def test_android_custom_mapping_remains_supported(self) -> None:
        build_types = matrix.parse_build_types(
            '*:dbg:Debug\nandroid:benchmark:bundleBenchmark\n'
        )
        entries = matrix.resolve_matrix_selection(
            'platforms',
            ['android-clang-arm64-dll'],
            build_types,
        )
        self.assertEqual(
            [('android-clang-arm64-dll', 'benchmark', 'bundleBenchmark')],
            entries,
        )


class StructuredDataTest(unittest.TestCase):
    def capture(self, function, *arguments: str) -> str:
        output = StringIO()
        with redirect_stdout(output):
            function(*arguments)
        return output.getvalue()

    def test_build_type_json_is_validated(self) -> None:
        self.assertEqual(
            {'dbg': 'Debug', 'rel': 'Release'},
            ci_data.parse_json_mapping(
                '{ "dbg": "Debug", "rel": "Release" }'
            ),
        )
        with self.assertRaises(ValueError):
            ci_data.parse_json_mapping('[]')

    def test_build_type_json_is_compacted_for_github_environment(self) -> None:
        self.assertEqual(
            '{"dbg":"Debug","rel":"Release"}\n',
            self.capture(
                ci_data.normalize_build_types,
                '{\n  "dbg": "Debug",\n  "rel": "Release"\n}',
            ),
        )

    def test_structured_output_uses_lf_on_windows(self) -> None:
        output = BytesIO()
        stream = type('BinaryStream', (), {'buffer': output})()
        with patch.object(ci_data.sys, 'stdout', stream):
            ci_data.write_output('dbg\tDebug')
        self.assertEqual(b'dbg\tDebug\n', output.getvalue())

    def test_platform_mapping_prefers_platform_entries(self) -> None:
        self.assertEqual(
            '{"benchmark":"bundleBenchmark"}\n',
            self.capture(
                ci_data.select_platform_build_types,
                'android',
                '*:dbg:Debug\nandroid:benchmark:bundleBenchmark\n',
            ),
        )

    def test_path_lists_reject_semicolons(self) -> None:
        with self.assertRaises(ValueError):
            ci_data.parse_list('paths', 'first;second')


class CompositeActionContractTest(unittest.TestCase):
    ACTIONS = REPO_ROOT / '.github' / 'actions'

    def assert_contract(
        self,
        action: str,
        inputs: set[str],
        outputs: set[str],
    ) -> None:
        path = self.ACTIONS / action / 'action.yml'
        self.assertEqual(inputs, yaml_section_keys(path, 'inputs'))
        self.assertEqual(outputs, yaml_section_keys(path, 'outputs'))

    def test_prepare_matrix_contract(self) -> None:
        self.assert_contract(
            'ci-prepare-matrix',
            {'profile', 'platforms', 'build_types'},
            {
                'requested_platform_tags',
                'platform_tags',
                'platform_matrix',
                'build_matrix',
            },
        )

    def test_prepare_platform_contract(self) -> None:
        self.assert_contract(
            'ci-prepare-platform',
            {
                'profile',
                'ci_platform_tag',
                'build_types',
                'project_dir',
                'cmake_prefix_path',
            },
            {'build_cache_hit', 'engine_thirdparty_used', 'cmake_prefix_path'},
        )

    def test_build_project_contract(self) -> None:
        self.assert_contract(
            'ci-build-project',
            {
                'project_dir',
                'build_dir',
                'install_dir',
                'build_types',
                'cmake_cache_vars',
                'android_dir',
            },
            {'build_dir', 'install_dir'},
        )

    def test_wait_for_build_contract(self) -> None:
        self.assert_contract(
            'ci-wait-for-build',
            {
                'job_name',
                'artifact_names',
                'timeout_seconds',
                'artifact_grace_seconds',
                'token',
            },
            {'conclusion', 'completed_at', 'artifact_ids'},
        )


if __name__ == '__main__':
    unittest.main()
