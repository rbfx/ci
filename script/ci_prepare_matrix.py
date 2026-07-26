#!/usr/bin/env python3

"""Prepare grouped or per-configuration rbfx workflow matrices."""

from __future__ import annotations

import json
import os

from ci_data import (
    DEFAULT_BUILD_TYPE_RULES,
    PLATFORM_TAGS,
    SUPPORTED_PLATFORMS,
    parse_build_type_rules,
    parse_platform_tag,
    resolve_build_types,
    resolve_host_platform_tag,
    resolve_runs_on,
)


MatrixEntry = tuple[str, str, str]


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        raise SystemExit(f'Missing required environment variable: {name}')
    return value


def parse_lines(name: str) -> list[str]:
    return [
        value.strip()
        for value in require_env(name).splitlines()
        if value.strip()
    ]


def parse_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None or not value.strip():
        return default
    normalized = value.strip().lower()
    if normalized in {'true', '1'}:
        return True
    if normalized in {'false', '0'}:
        return False
    raise SystemExit(f'{name} must be true or false')


def split_selector(selector: str) -> tuple[str, str | None]:
    platform_selector, separator, build_type = selector.rpartition('@')
    if not separator:
        return selector, None
    if not platform_selector or not build_type:
        raise ValueError(f'invalid selector: {selector}')
    return platform_selector, build_type


def expand_platform_selector(selector: str) -> list[str]:
    if selector == 'all':
        return list(PLATFORM_TAGS)
    if selector in PLATFORM_TAGS:
        return [selector]
    if selector in SUPPORTED_PLATFORMS:
        prefix = f'{selector}-'
        return [tag for tag in PLATFORM_TAGS if tag.startswith(prefix)]
    return []


def expand_selector(
    selector: str,
    build_type_rules: dict[str, dict[str, str]],
) -> list[MatrixEntry]:
    try:
        platform_selector, selected_build_type = split_selector(selector)
    except ValueError:
        return []
    platform_tags = expand_platform_selector(platform_selector)
    entries: list[MatrixEntry] = []
    for platform_tag in platform_tags:
        platform, _compiler, _arch, _lib_type = parse_platform_tag(platform_tag)
        build_types = resolve_build_types(platform, build_type_rules)
        if selected_build_type is None:
            entries.extend(
                (platform_tag, short_name, configuration)
                for short_name, configuration in build_types.items()
            )
        elif selected_build_type in build_types:
            entries.append(
                (
                    platform_tag,
                    selected_build_type,
                    build_types[selected_build_type],
                )
            )
    return entries


def resolve_selection(
    requested_selectors: list[str],
    build_type_rules: dict[str, dict[str, str]],
) -> list[MatrixEntry]:
    include_selectors: list[str] = []
    exclude_selectors: list[str] = []
    for token in requested_selectors:
        if token.startswith('-'):
            selector = token[1:].strip()
            if not selector:
                raise SystemExit('platforms may not contain an empty exclusion')
            if selector == 'all':
                raise SystemExit('platforms does not support excluding all')
            exclude_selectors.append(selector)
        else:
            include_selectors.append(token)

    if not include_selectors:
        include_selectors = ['all']

    entries: list[MatrixEntry] = []
    unknown_selectors: list[str] = []
    for selector in include_selectors:
        matches = expand_selector(selector, build_type_rules)
        if matches:
            entries.extend(matches)
        else:
            unknown_selectors.append(selector)

    excluded_entries: set[MatrixEntry] = set()
    for selector in exclude_selectors:
        matches = expand_selector(selector, build_type_rules)
        if matches:
            excluded_entries.update(matches)
        else:
            unknown_selectors.append(selector)

    if unknown_selectors:
        raise SystemExit(
            'Unsupported platforms selector: '
            + ', '.join(dict.fromkeys(unknown_selectors))
        )

    entries = list(dict.fromkeys(entries))
    entries = [entry for entry in entries if entry not in excluded_entries]
    if not entries:
        raise SystemExit(
            'No matrix entries remain after filtering. Adjust platforms.'
        )
    return entries


def matrix_base(platform_tag: str, build_type: str = '') -> dict[str, str]:
    suffix = f'-{build_type}' if build_type else ''
    host_platform_tag = resolve_host_platform_tag(platform_tag)
    return {
        'ci_platform_tag': platform_tag,
        'ci_host_platform_tag': host_platform_tag,
        'ci_job_name': f'{platform_tag}{suffix}',
        'ci_host_job_name': f'{host_platform_tag}{suffix}',
        'runs_on': resolve_runs_on(platform_tag),
    }


def build_matrix(
    entries: list[MatrixEntry],
    separate_build_types: bool,
) -> dict[str, list[dict[str, object]]]:
    if separate_build_types:
        return {
            'include': [
                {
                    **matrix_base(platform_tag, short_name),
                    'ci_build_type': short_name,
                    'ci_build_types': {short_name: configuration},
                }
                for platform_tag, short_name, configuration in entries
            ]
        }

    grouped_build_types: dict[str, dict[str, str]] = {}
    for platform_tag, short_name, configuration in entries:
        grouped_build_types.setdefault(platform_tag, {})[
            short_name
        ] = configuration
    return {
        'include': [
            {
                **matrix_base(platform_tag),
                'ci_build_type': '',
                'ci_build_types': build_types,
            }
            for platform_tag, build_types in grouped_build_types.items()
        ]
    }


def write_matrix(matrix: dict[str, list[dict[str, object]]]) -> None:
    github_output = require_env('GITHUB_OUTPUT')
    with open(github_output, 'a', encoding='utf-8') as output:
        print(f'matrix={json.dumps(matrix, separators=(",", ":"))}', file=output)


def main() -> None:
    requested_selectors = parse_lines('INPUT_PLATFORMS')
    raw_build_types = os.environ.get('INPUT_BUILD_TYPES', '').strip()
    try:
        build_type_rules = parse_build_type_rules(
            raw_build_types or DEFAULT_BUILD_TYPE_RULES
        )
    except ValueError as error:
        raise SystemExit(f'Error: {error}') from error
    entries = resolve_selection(requested_selectors, build_type_rules)
    write_matrix(build_matrix(
        entries,
        parse_bool('INPUT_SEPARATE_BUILD_TYPES'),
    ))


if __name__ == '__main__':
    main()
