#!/usr/bin/env python3

"""Prepare the workflow platform matrix from action inputs."""

import json
import os


ALL_PLATFORM_TAGS = [
    'windows-msvc-x64-dll',
    'windows-msvc-x64-lib',
    'windows-msvc-x86-dll',
    'windows-msvc-x86-lib',
    'linux-gcc-x64-dll',
    'linux-gcc-x64-lib',
    'linux-clang-x64-dll',
    'linux-clang-x64-lib',
    'macos-clang-arm64-dll',
    'macos-clang-arm64-lib',
    'macos-clang-x64-dll',
    'macos-clang-x64-lib',
    'uwp-msvc-x64-dll',
    'uwp-msvc-x64-lib',
    'android-clang-arm64-dll',
    'android-clang-arm-dll',
    'android-clang-x64-dll',
    'ios-clang-arm-lib',
    'ios-clang-arm64-lib',
    'web-emscripten-wasm-lib',
]

DEFAULT_BUILD_TYPES = """\
*:dbg:Debug
*:rel:RelWithDebInfo
android:dbg:assembleDebug
android:rel:assembleRelease
"""


def require_env(name: str) -> str:
    value = os.environ.get(name)
    if value is None:
        raise SystemExit(f'Missing required environment variable: {name}')
    return value


def parse_csv_env(name: str) -> list[str]:
    raw_value = require_env(name)
    return [value.strip() for value in raw_value.split(',') if value.strip()]


def validate_choice(name: str, value: str, supported_values: set[str]) -> None:
    if value not in supported_values:
        raise SystemExit(f'Unsupported {name}: {value}')


def parse_build_types(raw_value: str) -> list[tuple[str, str, str]]:
    build_types: list[tuple[str, str, str]] = []
    for line_number, raw_line in enumerate(raw_value.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue

        parts = [part.strip() for part in line.split(':')]
        if len(parts) != 3 or any(not part for part in parts):
            raise SystemExit(
                f'Invalid build_types entry on line {line_number}: {raw_line!r}. '
                'Expected <platform>:<short-name>:<build-type-name>.'
            )

        platform, short_name, build_type_name = parts
        if platform != '*' and platform not in {
            tag.split('-', maxsplit=1)[0] for tag in ALL_PLATFORM_TAGS
        }:
            raise SystemExit(
                f'Unsupported build_types platform on line {line_number}: {platform}'
            )

        if any(
            selector == platform and existing_short_name == short_name
            for selector, existing_short_name, _build_type_name in build_types
        ):
            raise SystemExit(
                f'Duplicate build_types mapping on line {line_number}: '
                f'{platform}:{short_name}'
            )
        build_types.append((platform, short_name, build_type_name))

    if not build_types:
        raise SystemExit('build_types must contain at least one build configuration')
    return build_types


def resolve_platform_build_types(
    platform_tag: str,
    build_types: list[tuple[str, str, str]],
) -> dict[str, str]:
    platform = platform_tag.split('-', maxsplit=1)[0]
    platform_build_types = {
        short_name: build_type_name
        for selector, short_name, build_type_name in build_types
        if selector == platform
    }
    if platform_build_types:
        return platform_build_types

    return {
        short_name: build_type_name
        for selector, short_name, build_type_name in build_types
        if selector == '*'
    }


def expand_platform_tokens(tokens: list[str]) -> tuple[list[str], list[str]]:
    expanded_tags: list[str] = []
    unknown_tokens: list[str] = []
    for token in tokens:
        if token == 'all':
            expanded_tags.append(token)
            continue

        token_parts = [part for part in token.split('-') if part]
        if not token_parts:
            unknown_tokens.append(token)
            continue

        matches = []
        for known_tag in ALL_PLATFORM_TAGS:
            known_tag_parts = known_tag.split('-')
            if all(part in known_tag_parts for part in token_parts):
                matches.append(known_tag)

        if matches:
            expanded_tags.extend(matches)
        else:
            unknown_tokens.append(token)

    return list(dict.fromkeys(expanded_tags)), list(dict.fromkeys(unknown_tokens))


def split_build_type_selector(
    selector: str,
    build_types: list[tuple[str, str, str]],
) -> tuple[str, str | None]:
    short_names = sorted(
        {short_name for _platform, short_name, _build_type_name in build_types},
        key=len,
        reverse=True,
    )
    for short_name in short_names:
        suffix = f'-{short_name}'
        if selector.endswith(suffix):
            return selector[:-len(suffix)], short_name
    return selector, None


def expand_matrix_selector(
    selector: str,
    build_types: list[tuple[str, str, str]],
) -> list[tuple[str, str, str]]:
    platform_selector, selected_build_type = split_build_type_selector(
        selector,
        build_types,
    )
    expanded_platform_tags, unknown_platform_tags = expand_platform_tokens(
        [platform_selector]
    )
    if unknown_platform_tags:
        return []
    if 'all' in expanded_platform_tags:
        expanded_platform_tags = list(ALL_PLATFORM_TAGS)

    entries: list[tuple[str, str, str]] = []
    for platform_tag in expanded_platform_tags:
        platform_build_types = resolve_platform_build_types(
            platform_tag,
            build_types,
        )
        if selected_build_type is not None:
            build_type_name = platform_build_types.get(selected_build_type)
            if build_type_name is not None:
                entries.append(
                    (platform_tag, selected_build_type, build_type_name)
                )
        else:
            entries.extend(
                (platform_tag, short_name, build_type_name)
                for short_name, build_type_name in platform_build_types.items()
            )
    return entries


def resolve_matrix_selection(
    selector_name: str,
    requested_tokens: list[str],
    build_types: list[tuple[str, str, str]],
) -> list[tuple[str, str, str]]:
    include_selectors: list[str] = []
    exclude_selectors: list[str] = []
    for token in requested_tokens:
        if token.startswith('-'):
            selector = token[1:].strip()
            if not selector:
                raise SystemExit(f'{selector_name} may not contain an empty exclusion')
            if selector == 'all':
                raise SystemExit(f'{selector_name} does not support excluding all')
            exclude_selectors.append(selector)
        else:
            include_selectors.append(token)

    if not include_selectors:
        include_selectors = ['all']

    entries: list[tuple[str, str, str]] = []
    unknown_selectors: list[str] = []
    for selector in include_selectors:
        matches = expand_matrix_selector(selector, build_types)
        if matches:
            entries.extend(matches)
        else:
            unknown_selectors.append(selector)

    excluded_entries: set[tuple[str, str, str]] = set()
    for selector in exclude_selectors:
        platform_selector, _build_type = split_build_type_selector(
            selector,
            build_types,
        )
        _expanded_platforms, unknown_platforms = expand_platform_tokens(
            [platform_selector]
        )
        if unknown_platforms:
            unknown_selectors.append(selector)
            continue
        excluded_entries.update(expand_matrix_selector(selector, build_types))

    if unknown_selectors:
        raise SystemExit(
            f'Unsupported {selector_name}: '
            + ', '.join(dict.fromkeys(unknown_selectors))
        )

    entries = list(dict.fromkeys(entries))
    if excluded_entries:
        entries = [entry for entry in entries if entry not in excluded_entries]
    if not entries:
        raise SystemExit(
            f'No matrix entries remain after filtering. Adjust {selector_name}.'
        )
    return entries


def resolve_runs_on(platform_tag: str) -> str:
    if platform_tag.startswith(('windows-', 'uwp-')):
        return 'windows-latest'
    if platform_tag.startswith(('macos-', 'ios-')):
        return 'macos-latest'
    return 'ubuntu-latest'


def resolve_host_platform_tag(platform_tag: str) -> str:
    platform, _compiler, _arch, lib_type = platform_tag.split('-')
    if platform in {'android', 'web'}:
        return f'linux-gcc-x64-{lib_type}'
    if platform == 'ios':
        return f'macos-clang-x64-{lib_type}'
    if platform == 'uwp':
        return f'windows-msvc-x64-{lib_type}'
    return platform_tag


def build_matrix_base_entry(
    platform_tag: str,
) -> dict[str, bool | str]:
    host_platform_tag = resolve_host_platform_tag(platform_tag)
    host_platform, host_compiler, host_arch, _host_lib_type = host_platform_tag.split('-')
    return {
        'ci_platform_tag': platform_tag,
        'ci_host_platform_tag': host_platform_tag,
        'ci_host_platform': host_platform,
        'ci_host_compiler': host_compiler,
        'ci_host_arch': host_arch,
        'runs_on': resolve_runs_on(platform_tag),
    }


def build_build_matrix(
    matrix_entries: list[tuple[str, str, str]],
    requested_selectors: list[str],
) -> dict[str, list[dict[str, bool | str]]]:
    requested_selector_set = set(requested_selectors)
    return {
        'include': [
            {
                **build_matrix_base_entry(platform_tag),
                'ci_build_type': build_type,
                'ci_build_type_name': build_type_name,
                'requested': (
                    platform_tag in requested_selector_set
                    or f'{platform_tag}-{build_type}' in requested_selector_set
                ),
            }
            for platform_tag, build_type, build_type_name in matrix_entries
        ]
    }


def build_platform_matrix(
    matrix_entries: list[tuple[str, str, str]],
    requested_selectors: list[str],
) -> dict[str, list[dict[str, object]]]:
    requested_selector_set = set(requested_selectors)
    grouped_build_types: dict[str, dict[str, str]] = {}
    for platform_tag, build_type, build_type_name in matrix_entries:
        grouped_build_types.setdefault(platform_tag, {})[build_type] = build_type_name

    return {
        'include': [
            {
                **build_matrix_base_entry(platform_tag),
                'ci_build_types': build_types,
                'requested': (
                    platform_tag in requested_selector_set
                    or any(
                        f'{platform_tag}-{build_type}' in requested_selector_set
                        for build_type in build_types
                    )
                ),
            }
            for platform_tag, build_types in grouped_build_types.items()
        ]
    }


def write_output(
    requested_selectors: list[str],
    matrix_entries: list[tuple[str, str, str]],
) -> None:
    github_output = require_env('GITHUB_OUTPUT')
    platform_matrix = build_platform_matrix(
        matrix_entries,
        requested_selectors,
    )
    build_matrix = build_build_matrix(
        matrix_entries,
        requested_selectors,
    )
    platform_tags = list(
        dict.fromkeys(platform_tag for platform_tag, _short, _name in matrix_entries)
    )
    with open(github_output, 'a', encoding='utf-8') as output:
        print(f'requested_platform_tags={json.dumps(requested_selectors)}', file=output)
        print(f'platform_tags={json.dumps(platform_tags)}', file=output)
        print(f'platform_matrix={json.dumps(platform_matrix)}', file=output)
        print(f'build_matrix={json.dumps(build_matrix)}', file=output)


def main() -> None:
    profile = os.environ.get('INPUT_PROFILE', 'downstream').strip() or 'downstream'
    validate_choice('profile', profile, {'engine', 'downstream'})

    requested_platform_tags = parse_csv_env('INPUT_PLATFORMS')
    build_types = parse_build_types(
        os.environ.get('INPUT_BUILD_TYPES', DEFAULT_BUILD_TYPES)
    )

    matrix_entries = resolve_matrix_selection(
        'platforms',
        requested_platform_tags,
        build_types,
    )
    write_output(requested_platform_tags, matrix_entries)


if __name__ == '__main__':
    main()
