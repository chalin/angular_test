// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:angular_test/src/bin/logging.dart';
import 'package:angular_test/src/util.dart';
import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:stack_trace/stack_trace.dart';

final _pubBin = Platform.isWindows ? 'pub.bat' : 'pub';
final RegExp _serveRegexp = new RegExp(r'^Serving\s+.*\s+on\s+(.*)$');

/// Runs all tests using `pub run test` in the specified directory.
///
/// Tests that require AoT code generation proxies through `pub serve`.
main(List<String> args) async {
  initLogging('angular_test.bin.run');
  final parsedArgs = _argParser.parse(args);
  final pubspecFile = new File(p.join(parsedArgs['package'], 'pubspec.yaml'));
  if (!pubspecFile.existsSync()) {
    error('No "pubspec.yaml" found at ${pubspecFile.path}');
    _usage();
  }
  bool verbose = parsedArgs['verbose'];
  if (!verbose) {
    var logFile = new File(
        p.join(Directory.systemTemp.path, 'angular_test_pub_serve_output.log'));
    logFile.createSync();
    log("The pub serve output is at ${logFile.uri.toFilePath()}");
    initFileWriting(logFile.openWrite());
  }

  Process pubServeProcess;

  void killPub() {
    if (pubServeProcess != null) {
      log("Shutting down...");
      if (!pubServeProcess.kill()) {
        // Good FYI...
        log('`pub serve` was not terminated.');
      }
      pubServeProcess = null;
    }
  }

  await Chain.capture(() async {
    var testsRunning = false;
    // Run pub serve, and wait for significant messages.
    pubServeProcess = await Process
        .start(_pubBin, ['serve', 'test', '--port=${parsedArgs['port']}']);
    Uri serveUri;
    var stdoutFuture =
        standardIoToLines(pubServeProcess.stdout).forEach((message) async {
      if (serveUri == null) {
        // need to find the origin on which pub serve is started
        Match serveMatch = _serveRegexp.firstMatch(message);
        if (serveMatch != null) {
          serveUri = Uri.parse(serveMatch[1]);
          log('pub serve started on: ${serveUri}');
        }
      }
      if (message.contains('Serving angular_testing')) {
        log('Using pub serve to generate AoT code for AngularDart...');
      } else if (message.contains('Build completed successfully')) {
        if (testsRunning) {
          throw new StateError('Should only get this output once.');
        }
        if (serveUri == null) {
          throw new StateError('Could not determine serve host and port.');
        }
        success('Finished AoT compilation. Running tests...');
        testsRunning = true;
        exitCode = await _runTests(
            includeFlags: parsedArgs['run-test-flag'],
            includePlatforms: parsedArgs['platform'],
            testNames: parsedArgs['name'],
            testPlainNames: parsedArgs['plain-name'],
            port: serveUri.port);
        killPub();
      } else {
        log(message, verbose: verbose);
      }
    });
    var stderrFuture =
        standardIoToLines(pubServeProcess.stderr).forEach((String message) {
      error(message, verbose: verbose);
    });
    await Future.wait([
      stdoutFuture,
      stderrFuture,
      pubServeProcess.exitCode
    ]).whenComplete(() async {
      await closeIOSink();
    });
  }, onError: (e, chain) {
    error([e, chain.terse].join('\n').trim(), exception: e, stack: chain);
    killPub();
    exitCode = 1;
  });
}

Future<int> _runTests(
    {List<String> includeFlags: const ['aot'],
    List<String> includePlatforms: const ['content-shell'],
    List<String> testNames,
    List<String> testPlainNames,
    int port}) async {
  if (port == 0) {
    throw new ArgumentError.value(port, 'port must not be `0`');
  }
  final args = ['run', 'test', '--pub-serve=$port'];
  args.addAll(includeFlags.map((f) => '-t $f'));
  if (testNames != null) args.addAll(testNames.map((n) => '--name=$n'));
  if (testPlainNames != null)
    args.addAll(testPlainNames.map((n) => '--plain-name=$n'));
  args.add('--platform=${includePlatforms.map((p) => p.trim()).join(' ')}');
  final process = await Process.start(_pubBin, args);
  await Future.wait([
    standardIoToLines(process.stderr).forEach(error),
    standardIoToLines(process.stdout).forEach(log),
  ]);

  return await process.exitCode;
}

void _usage() {
  log(_argParser.usage);
  exitCode = 1;
}

final _argParser = new ArgParser()
  ..addOption(
    'run-test-flag',
    abbr: 't',
    help: 'What flag(s) to include when running "pub run test"',
    valueHelp: ''
        'In order to have a fast test cycle, we only want to run tests '
        'that have AoT required (all the ones created using this '
        'package do).',
    defaultsTo: 'aot',
    allowMultiple: true,
  )
  ..addOption(
    'package',
    help: 'What directory containing a pub package to run tests in',
    valueHelp: p.join('some', 'path', 'to', 'package'),
    defaultsTo: p.current,
  )
  ..addOption(
    'platform',
    abbr: 'p',
    help: 'What platform(s) to pass to pub run test',
    valueHelp: 'Common examples are "content-shell", "dartium", "chrome"',
    defaultsTo: 'content-shell',
    allowMultiple: true,
  )
  ..addOption(
    'name',
    abbr: 'n',
    help: 'A substring of the name of the test to run.\n'
        'Regular expression syntax is supported.\n'
        'If passed multiple times, tests must match all substrings.',
    allowMultiple: true,
    splitCommas: false,
  )
  ..addOption(
    'plain-name',
    abbr: 'N',
    help: 'A plain-text substring of the name of the test to run.\n'
        'If passed multiple times, tests must match all substrings.',
    allowMultiple: true,
    splitCommas: false,
  )
  ..addOption('port',
      help: 'What port to use for pub serve.\n',
      valueHelp:
          'Using port `0`, a random port will be assigned to pub serve.\n',
      defaultsTo: '8080')
  ..addFlag(
    'verbose',
    abbr: 'v',
    help: 'Whether to display pub serve output as well when running tests.\n'
        'Defaults to false.',
    defaultsTo: false,
  );
