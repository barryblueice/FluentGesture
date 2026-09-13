"""Run the Windows AXTree regression in a separate build and native host.

Usage: python tools/test_accessibility.py --flutter-sdk D:/flutter
No production process, config, tray or input registration is touched.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--flutter-sdk', type=Path, required=True)
    parser.add_argument('--test-name', help='Run one named integration test while diagnosing a failure')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    project = root / 'build' / 'accessibility-project'
    project.mkdir(parents=True, exist_ok=True)
    for name in ('lib', 'windows', 'test', 'tests', 'integration_test'):
        shutil.copytree(root / name, project / name, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns('ephemeral', '__pycache__'))
    for name in ('pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml'):
        shutil.copy2(root / name, project / name)
    flutter = [str(args.flutter_sdk / 'bin/cache/dart-sdk/bin/dart.exe'),
               str(args.flutter_sdk / 'bin/cache/flutter_tools.snapshot'),
               '--no-version-check']
    subprocess.run(flutter + ['pub', 'get', '--offline'], cwd=project, check=True)
    native_log = project / 'build/windows/x64/runner/Debug/accessibility-native.log'
    native_log.unlink(missing_ok=True)
    command = flutter + ['test', 'integration_test/accessibility_test.dart',
                         '-d', 'windows', '--dart-define=FLUENT_GESTURE_UI_TEST=true']
    if args.test_name:
        command += ['--plain-name', args.test_name]
    log = root / 'build/validation/accessibility.log'
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('w', encoding='utf-8') as output:
        process = subprocess.Popen(command, cwd=project, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, encoding='utf-8', errors='replace')
        for line in process.stdout:
            output.write(line)
            output.flush()
            print(line, end='', flush=True)
        code = process.wait()
    native_output = native_log.read_text(encoding='utf-8', errors='replace') if native_log.exists() else ''
    (log.parent / 'accessibility-native.log').write_text(native_output, encoding='utf-8')
    print(native_output)
    if code:
        return code
    if 'AXTEST: native accessibility requested' not in native_output:
        print('FAIL: native accessibility host was not activated')
        return 1
    if 'Failed to update ui::AXTree' in native_output + log.read_text(encoding='utf-8'):
        print('FAIL: native AXTree rejected a semantics update')
        return 1
    print('PASS: Windows accessibility enabled; no AXTree update errors')
    return 0


if __name__ == '__main__':
    sys.exit(main())
