#!/usr/bin/env python3

"""Canonical structured data and platform rules for rbfx CI."""

from __future__ import annotations

from datetime import datetime
import json
import sys


PLATFORM_TAGS = (
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
)
SUPPORTED_PLATFORMS = {
    tag.split('-', maxsplit=1)[0]
    for tag in PLATFORM_TAGS
}
DEFAULT_BUILD_TYPE_RULES = """\
*:dbg:Debug
*:rel:RelWithDebInfo
android:dbg:assembleDebug
android:rel:assembleRelease
"""


def write_output(value: str) -> None:
    """Write UTF-8 with LF endings, including when invoked from Git Bash."""
    output = value + ('\n' if value else '')
    binary_stream = getattr(sys.stdout, 'buffer', None)
    if binary_stream is None:
        sys.stdout.write(output)
    else:
        binary_stream.write(output.encode('utf-8'))


def parse_platform_tag(platform_tag: str) -> tuple[str, str, str, str]:
    if platform_tag not in PLATFORM_TAGS:
        raise ValueError(f'unsupported CI platform tag: {platform_tag}')
    platform, compiler, arch, lib_type = platform_tag.split('-')
    return platform, compiler, arch, lib_type


def platform_group(platform: str) -> str:
    if platform in {'windows', 'linux', 'macos'}:
        return 'desktop'
    if platform in {'android', 'ios'}:
        return 'mobile'
    if platform in {'uwp', 'web'}:
        return platform
    raise ValueError(f'unsupported platform: {platform}')


def resolve_runs_on(platform_tag: str) -> str:
    platform, _compiler, _arch, _lib_type = parse_platform_tag(platform_tag)
    if platform in {'windows', 'uwp'}:
        return 'windows-latest'
    if platform in {'macos', 'ios'}:
        return 'macos-latest'
    return 'ubuntu-latest'


def resolve_host_platform_tag(platform_tag: str) -> str:
    platform, _compiler, _arch, lib_type = parse_platform_tag(platform_tag)
    if platform in {'android', 'web'}:
        return f'linux-gcc-x64-{lib_type}'
    if platform == 'ios':
        return f'macos-clang-x64-{lib_type}'
    if platform == 'uwp':
        return f'windows-msvc-x64-{lib_type}'
    return platform_tag


def parse_json_mapping(raw_value: str) -> dict[str, str]:
    try:
        value = json.loads(raw_value)
    except json.JSONDecodeError as error:
        raise ValueError(f'invalid JSON object: {error}') from error
    return validate_build_type_mapping(value)


def validate_build_type_mapping(value: object) -> dict[str, str]:
    if not isinstance(value, dict) or not value:
        raise ValueError('value must be a non-empty build type map')
    if any(
        not isinstance(short_name, str)
        or not short_name
        or '@' in short_name
        or not isinstance(configuration, str)
        or not configuration
        or any(
            character in short_name + configuration
            for character in '\r\n\t'
        )
        for short_name, configuration in value.items()
    ):
        raise ValueError(
            'keys and values must be non-empty strings without control whitespace; '
            'keys may not contain @'
        )
    return value


def parse_build_type_mappings(raw_value: str) -> dict[str, str]:
    if raw_value.lstrip().startswith(('{', '[')):
        raise ValueError(
            'build_types must contain one <short-name>:<configuration> '
            'mapping per line, not JSON'
        )

    mappings: dict[str, str] = {}
    for line_number, raw_line in enumerate(raw_value.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(':', maxsplit=1)]
        if len(parts) != 2 or any(not part for part in parts):
            raise ValueError(
                f'invalid build_types entry on line {line_number}: {raw_line!r}; '
                'expected <short-name>:<configuration>'
            )
        short_name, configuration = parts
        if short_name in mappings:
            raise ValueError(
                f'duplicate mapping on line {line_number}: {short_name}'
            )
        mappings[short_name] = configuration
    if not mappings:
        raise ValueError('build_types must contain at least one mapping')
    return validate_build_type_mapping(mappings)


def parse_build_type_rules(raw_value: str) -> dict[str, dict[str, str]]:
    rules: dict[str, dict[str, str]] = {}
    for line_number, raw_line in enumerate(raw_value.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(':', maxsplit=2)]
        if len(parts) != 3 or any(not part for part in parts):
            raise ValueError(
                f'invalid build_types entry on line {line_number}: {raw_line!r}; '
                'expected <platform>:<short-name>:<configuration>'
            )
        selector, short_name, configuration = parts
        if selector != '*' and selector not in SUPPORTED_PLATFORMS:
            raise ValueError(
                f'unsupported platform on line {line_number}: {selector}'
            )
        if '@' in short_name or any(
            character in short_name + configuration
            for character in '\r\n\t'
        ):
            raise ValueError(
                f'invalid build_types entry on line {line_number}: '
                'short names may not contain @ or control whitespace'
            )
        mappings = rules.setdefault(selector, {})
        if short_name in mappings:
            raise ValueError(
                f'duplicate mapping on line {line_number}: '
                f'{selector}:{short_name}'
            )
        mappings[short_name] = configuration

    if not rules:
        raise ValueError('build_types must contain at least one mapping')
    return rules


def resolve_build_types(
    platform: str,
    rules: dict[str, dict[str, str]],
) -> dict[str, str]:
    if platform not in SUPPORTED_PLATFORMS:
        raise ValueError(f'unsupported platform: {platform}')
    mappings = rules.get(platform, rules.get('*', {}))
    if not mappings:
        raise ValueError(
            f'no build configurations are defined for platform {platform!r}'
        )
    return dict(mappings)


def default_build_types(platform: str) -> dict[str, str]:
    return resolve_build_types(
        platform,
        parse_build_type_rules(DEFAULT_BUILD_TYPE_RULES),
    )


def build_types_tsv(raw_value: str) -> None:
    write_output('\n'.join(
        f'{short_name}\t{configuration}'
        for short_name, configuration in parse_json_mapping(raw_value).items()
    ))


def normalize_build_types(raw_value: str) -> None:
    write_output(json.dumps(
        parse_json_mapping(raw_value),
        separators=(',', ':'),
    ))


def normalize_build_type_lines(raw_value: str) -> None:
    write_output(json.dumps(
        parse_build_type_mappings(raw_value),
        separators=(',', ':'),
    ))


def write_default_build_types(platform: str) -> None:
    write_output(json.dumps(
        default_build_types(platform),
        separators=(',', ':'),
    ))


def write_platform_tsv(platform_tag: str) -> None:
    platform, compiler, arch, lib_type = parse_platform_tag(platform_tag)
    write_output('\t'.join((
        platform,
        compiler,
        arch,
        lib_type,
        platform_group(platform),
    )))


def parse_list(kind: str, raw_value: str) -> None:
    if raw_value.lstrip().startswith(('[', '{')):
        raise ValueError('value must contain one item per line, not JSON')
    values = [
        line.strip()
        for line in raw_value.splitlines()
        if line.strip()
    ]

    forbidden = '\r\n\t;' if kind == 'paths' else '\r\n\t'
    label = 'paths' if kind == 'paths' else 'values'
    if any(
        not isinstance(value, str)
        or not value
        or any(character in value for character in forbidden)
        for value in values
    ):
        raise ValueError(
            f'{label} must be non-empty strings without control whitespace'
            + (' or semicolons' if kind == 'paths' else '')
        )
    if values:
        write_output('\n'.join(values))


def iso_to_epoch(value: str) -> None:
    write_output(str(int(
        datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
    )))


def get_build_type(raw_value: str, short_name: str, default: str) -> None:
    write_output(parse_json_mapping(raw_value).get(short_name, default))


def main(arguments: list[str]) -> None:
    if not arguments:
        raise ValueError('a command is required')
    command, *values = arguments

    if command == 'build-types-tsv' and len(values) == 1:
        build_types_tsv(values[0])
    elif command == 'normalize-build-types' and len(values) == 1:
        normalize_build_types(values[0])
    elif command == 'normalize-build-type-lines' and len(values) == 1:
        normalize_build_type_lines(values[0])
    elif command == 'default-build-types' and len(values) == 1:
        write_default_build_types(values[0])
    elif command == 'platform-tsv' and len(values) == 1:
        write_platform_tsv(values[0])
    elif command == 'parse-list' and len(values) == 2:
        if values[0] not in {'paths', 'strings'}:
            raise ValueError('parse-list kind must be paths or strings')
        parse_list(values[0], values[1])
    elif command == 'iso-to-epoch' and len(values) == 1:
        iso_to_epoch(values[0])
    elif command == 'get-build-type' and len(values) == 3:
        get_build_type(values[0], values[1], values[2])
    else:
        raise ValueError(f'invalid arguments for command: {command}')


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except ValueError as error:
        raise SystemExit(f'Error: {error}') from error
