# CHANGELOG

## v2.7.2

- Fixes RSpec library hook bug introduced in v2.7.1 #230 - @malclocke

## v2.7.1

- Removes test links from job logs
- Rename Test Analytics to Test Engine

## v2.7.0

Features:

- Add configurable span filters #220 - @catkins

Fixes:

- Correctly report HTTP error during upload #223 - @zhming0

## v2.6.1

- Fix missing failed examples if rspec hooks fail #221 - @zhming0

## v2.6.0

- Trace spans can be filtered by minimum duration #215 - @pda

## v2.5.0

- Remove ActiveSupport as a primary dependancy #212 - @pat

## v2.4.0

- Feature release: Output links to Test Analytic tests within the rspec log #209 - @meghan-kradolfer

## v2.3.2

- Add support for Codeship #198 - @swebb
- Restore compatibility with older Ruby versions #201 - @gchan
- Report Ruby version to Test Analytics #203 - @gchan

## v2.3.1

- Log standard error raised during upload #195 - @nprizal

## v2.3.0

- Stop sending execution id and safeguard SecureRandom.uuid #192 - @niceking
- Rescue from StandardError when sending upload request #191 - @niceking
- Fix nil pointer #188 - @ChrisBr

## v2.2.0

- Gzip payload of request to Upload API #183 - @niceking

## v2.1.0

- Major change: deprecates websocket connection in favour of sending HTTP requests to the Upload API. In future, websocket support will be completely removed from Buildkite and only version 2.1+ of this gem will continue to work.

## v2.1.0.pre

- Minitest plugin to use HTTP Upload API instead of websocket connection to send test data #178 #179 - @niceking

## v2.0.0.pre

- Major change: RSpec plugin to use HTTP Upload API instead of websocket connection to send test data #174 #175 - @niceking
- `identifier` field removed from trace #176 - @amybiyuliu
- Only warn on EOF errors and also catch SSLErrors #160 - @gchan

## v1.5.0

- Send `failure_expanded` from minitest #171 - @nprizal

## v1.4.2

- Update collector argument in the Analytics::API payload #170 - @KatieWright26

## v1.4.1

- Add in support to create file with trace data #167

## v1.3.1

- Cope with the gem being loaded but not configured when using minitest #165 - @billhorsman

## v1.3.0

- Fix ETIMEDOUT during socket connection causing non-zero exit code #162 - @blaknite
- Add ability to pass custom run env to Test Analytics API #163 - @blaknite

## v1.2.5

- Relax activesupport dependency to >= 4.2.0 #155 - @noodl

## v1.2.4

- Fix sleep instrumentation errors without argument #153 - @JuanitoFatas

## v1.2.3

- Add ability to specify execution prefix/suffix #140 - @JuanitoFatas

## v1.1.3

- Use a private reference to JSON.parse to prevent it being mocked #149 - @ghcan

## v1.1.2

- Remove branch reference prefix in Github Actions #136 - @gchan
- Make ruby collector work better for non-web app #128 - @JuanitoFatas
- Avoid linters complaining about double quotes #137 - @SocalNick
- Revert "Allow specifying run name prefix and suffix" #139 - @JuanitoFatas
- Update Code of Conduct contact email address #143 - @JuanitoFatas
- Suppress errors when connecting to Buildkite #145 - @swebb
- Add some design documentation to understand how the gem works #146 - @swebb
- Fix logging level from debug to error #147 - @gchan

## v1.1.1

- Strip CR/LF from token input #127 - @gchan
- Allow specify run name prefix and suffix #130 - @juanitofatas
- Improve Minitest support by using after_teardown #131 - @davidstosik
- Avoid breaking test suite stubs `Process.clock_gettime` #132 - @juanitofatas (thanks @ChrisBR)

## v1.1.0

- Remove an internal debugging change #115 — @juanitofatas
- Remove warnings #116 - @juanitofatas
- Fix old gem name still in debugging and warning messages #117 - @juanitofatas
- Include module from `Minitest` #118 - @juanitofatas
- Fix Minitest loading without using minitest hook #125 — @paulca

## v1.0.1

- Fix project_dir issue expecting a string, not a Pathname #112 — @paulca

## v1.0.0

- Option to disable detailed tracing #108 - @blanknite
- minitest support (beta) #103 - @mariovisic, @blaknite
- Handle re-raised disconnect exceptions #102 - @JuantoFatas
- Make trace lookup faster using a Hash #98 - @blaknite, @mariovisic
- Introduce more configurable logging #97 - @JuanitoFatas

## v0.8.1

- Improve the EOT confirmation #93 — @blaknite

## v0.8.0

- Support multiple CI platforms and generic env #80 — @blaknite
- Replace invalid UTF-8 characters in test names #85 — @mariovisic
- Relax Active Support constraint #87 — @ags
