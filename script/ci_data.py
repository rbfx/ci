#!/usr/bin/env python3

"""Structured-data operations used by the rbfx CI shell entry points."""

from __future__ import annotations

from datetime import datetime
import json
import sys


SUPPORTED_PLATFORMS = {
    'windows',
    'linux',
    'macos',
    'uwp',
    'android',
    'ios',
    'web',
}


def parse_json_mapping(raw_value: str) -> dict[str, str]:
    try:
        value = json.loads(raw_value)
    except json.JSONDecodeError as error:
        raise ValueError(f'invalid JSON object: {error}') from error
    if not isinstance(value, dict) or not value:
        raise ValueError('value must be a non-empty JSON object')
    if any(
        not isinstance(short_name, str)
        or not short_name
        or not isinstance(configuration, str)
        or not configuration
        or any(
            character in short_name + configuration
            for character in '\r\n\t'
        )
        for short_name, configuration in value.items()
    ):
        raise ValueError(
            'keys and values must be non-empty strings without control whitespace'
        )
    return value


def build_types_tsv(raw_value: str) -> None:
    for short_name, configuration in parse_json_mapping(raw_value).items():
        print(f'{short_name}\t{configuration}')


def normalize_build_types(raw_value: str) -> None:
    print(json.dumps(parse_json_mapping(raw_value), separators=(',', ':')))


def select_platform_build_types(platform: str, raw_value: str) -> None:
    if platform not in SUPPORTED_PLATFORMS:
        raise ValueError(f'unsupported platform: {platform}')

    default_mappings: dict[str, str] = {}
    platform_mappings: dict[str, dict[str, str]] = {}
    for line_number, raw_line in enumerate(raw_value.splitlines(), start=1):
        line = raw_line.strip()
        if not line:
            continue
        parts = [part.strip() for part in line.split(':', maxsplit=2)]
        if len(parts) != 3 or any(not part for part in parts):
            raise ValueError(
                f'invalid entry on line {line_number}: {raw_line!r}; '
                'expected <platform>:<short-name>:<configuration>'
            )
        selector, short_name, configuration = parts
        if selector != '*' and selector not in SUPPORTED_PLATFORMS:
            raise ValueError(
                f'unsupported platform on line {line_number}: {selector}'
            )
        mappings = (
            default_mappings
            if selector == '*'
            else platform_mappings.setdefault(selector, {})
        )
        if short_name in mappings:
            raise ValueError(
                f'duplicate mapping on line {line_number}: '
                f'{selector}:{short_name}'
            )
        mappings[short_name] = configuration

    mappings = platform_mappings.get(platform, default_mappings)
    if not mappings:
        raise ValueError(
            f'no build configurations are defined for platform {platform!r}'
        )
    print(json.dumps(mappings, separators=(',', ':')))


def parse_list(kind: str, raw_value: str) -> None:
    if raw_value.lstrip().startswith('['):
        try:
            values = json.loads(raw_value)
        except json.JSONDecodeError as error:
            raise ValueError(f'invalid JSON array: {error}') from error
        if not isinstance(values, list):
            raise ValueError('value must be a JSON array')
    else:
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
        print('\n'.join(values))


def iso_to_epoch(value: str) -> None:
    print(int(datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()))


def get_build_type(raw_value: str, short_name: str, default: str) -> None:
    print(parse_json_mapping(raw_value).get(short_name, default))


def main(arguments: list[str]) -> None:
    if not arguments:
        raise ValueError('a command is required')
    command, *values = arguments

    if command == 'build-types-tsv' and len(values) == 1:
        build_types_tsv(values[0])
    elif command == 'normalize-build-types' and len(values) == 1:
        normalize_build_types(values[0])
    elif command == 'select-platform-build-types' and len(values) == 2:
        select_platform_build_types(values[0], values[1])
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
