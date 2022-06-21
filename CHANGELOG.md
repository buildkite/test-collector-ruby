# CHANGELOG

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
