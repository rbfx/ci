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
        rules = ci_data.parse_build_type_rules(
            ci_data.DEFAULT_BUILD_TYPE_RULES
        )
        entries = matrix.resolve_selection(['all'], rules)
        grouped = matrix.build_matrix(entries, False)['include']

        self.assertEqual(20, len(grouped))
        self.assertEqual(list(ci_data.PLATFORM_TAGS), [
            row['ci_platform_tag'] for row in grouped
        ])
        self.assertTrue(all(len(row['ci_build_types']) == 2 for row in grouped))
        self.assertTrue(all(row['ci_build_type'] == '' for row in grouped))

    def test_separate_build_types_have_same_resolved_map_contract(self) -> None:
        rules = ci_data.parse_build_type_rules(
            ci_data.DEFAULT_BUILD_TYPE_RULES
        )
        entries = matrix.resolve_selection(['all'], rules)
        separate = matrix.build_matrix(entries, True)['include']

        self.assertEqual(40, len(separate))
        self.assertEqual(40, len({
            row['ci_job_name']
            for row in separate
        }))
        self.assertTrue(all(len(row['ci_build_types']) == 1 for row in separate))
        self.assertTrue(all(
            row['ci_build_type'] in row['ci_build_types']
            for row in separate
        ))

    def test_android_custom_mapping_remains_supported(self) -> None:
        rules = ci_data.parse_build_type_rules(
            '*:dbg:Debug\nandroid:benchmark::app:bundleBenchmark\n'
        )
        entries = matrix.resolve_selection(
            ['android-clang-arm64-dll'],
            rules,
        )
        self.assertEqual(
            [
                (
                    'android-clang-arm64-dll',
                    'benchmark',
                    ':app:bundleBenchmark',
                )
            ],
            entries,
        )

    def test_exact_platform_tag_wins_over_build_type_name(self) -> None:
        rules = ci_data.parse_build_type_rules('*:lib:Debug')
        self.assertEqual(
            [('linux-gcc-x64-lib', 'lib', 'Debug')],
            matrix.resolve_selection(['linux-gcc-x64-lib'], rules),
        )

    def test_build_type_selector_uses_explicit_separator(self) -> None:
        rules = ci_data.parse_build_type_rules(
            ci_data.DEFAULT_BUILD_TYPE_RULES
        )
        entries = matrix.resolve_selection(['linux@dbg'], rules)
        self.assertEqual(4, len(entries))
        self.assertTrue(all(entry[1] == 'dbg' for entry in entries))


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
            {'benchmark': 'bundleBenchmark'},
            ci_data.resolve_build_types(
                'android',
                ci_data.parse_build_type_rules(
                    '*:dbg:Debug\nandroid:benchmark:bundleBenchmark\n'
                ),
            ),
        )

    def test_default_build_types_are_canonical(self) -> None:
        self.assertEqual(
            {'dbg': 'Debug', 'rel': 'RelWithDebInfo'},
            ci_data.default_build_types('linux'),
        )
        self.assertEqual(
            {'dbg': 'assembleDebug', 'rel': 'assembleRelease'},
            ci_data.default_build_types('android'),
        )

    def test_platform_metadata_comes_from_canonical_tags(self) -> None:
        self.assertEqual(
            ('ios', 'clang', 'arm64', 'lib'),
            ci_data.parse_platform_tag('ios-clang-arm64-lib'),
        )
        self.assertEqual(
            'macos-clang-x64-lib',
            ci_data.resolve_host_platform_tag('ios-clang-arm64-lib'),
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
            {'platforms', 'build_types', 'separate_build_types'},
            {'matrix'},
        )

    def test_prepare_platform_contract(self) -> None:
        self.assert_contract(
            'ci-prepare-platform',
            {
                'profile',
                'ci_platform_tag',
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
        action = (
            self.ACTIONS / 'ci-build-project' / 'action.yml'
        ).read_text(encoding='utf-8')
        self.assertIn(
            'inputs.build_types || '
            '(matrix.ci_build_types && toJSON(matrix.ci_build_types))',
            action,
        )
        self.assertIn('default-build-types "$ci_platform"', action)

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
